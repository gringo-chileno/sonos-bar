import Foundation
import Observation

struct Room: Identifiable, Hashable {
    let id: String   // RINCON_… UUID
    let name: String
    let host: String // ip:1400
    var volume: Int?
}

struct ZoneGroup: Identifiable {
    let id: String   // coordinator UUID
    let household: Int
    var rooms: [Room]
    var state = ""
    var title: String?
    var subtitle: String?
    var art: String?
    var volume: Int?

    var coordinator: Room { rooms.first { $0.id == id } ?? rooms[0] }
    var name: String { rooms.map(\.name).joined(separator: " + ") }
    var isPlaying: Bool { state == "PLAYING" || state == "TRANSITIONING" }
}

struct Favorite: Identifiable {
    let id: String
    let title: String
    let uri: String
    let meta: String
    let art: String?
    let isStation: Bool
}

@MainActor @Observable
final class SonosModel {
    var groups: [ZoneGroup] = []
    var favorites: [Int: [Favorite]] = [:]
    var expanded: String?
    var error: String?
    var loading = false
    /// The group currently playing the Mac's audio, if any.
    var macAudioGroup: String?

    /// One reachable speaker per Sonos system (S1 and S2 are separate systems).
    private var householdHosts: [String] = []
    private var polling: Task<Void, Never>?
    private let streamer = MacAudioStreamer()
    private var macAudioWatch: Task<Void, Never>?
    /// Mac audio and Spotify come out at very different loudness, so each keeps its own volume:
    /// the speakers' volume from before Mac audio started, put back when it stops.
    private var macAudioHost: String?
    private static let macVolumeKey = "macAudioVolume"
    private static let beforeMacKey = "volumeBeforeMac"
    /// Kept on disk so quitting or reinstalling the app mid-session doesn't lose it.
    private var volumeBeforeMac: Int? {
        get { UserDefaults.standard.object(forKey: Self.beforeMacKey) as? Int }
        set { UserDefaults.standard.set(newValue, forKey: Self.beforeMacKey) }
    }

    var allRooms: [Room] { groups.flatMap(\.rooms) }

    // MARK: Refresh

    func start() {
        polling?.cancel()
        polling = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop() {
        polling?.cancel()
        polling = nil
    }

    func refresh(rediscover: Bool = false) async {
        if rediscover || householdHosts.isEmpty {
            loading = true
            var found = await Task.detached { SonosAPI.discover() }.value
            if found.isEmpty { found = await Task.detached { SonosAPI.discover(seconds: 3) }.value }
            loading = false
            householdHosts = found.sorted()
            if found.isEmpty {
                error = "No Sonos speakers found on this network."
                groups = []
                return
            }
        }
        do {
            var newGroups = try await loadTopology()
            for i in newGroups.indices {
                await loadPlayback(&newGroups[i])
                if newGroups[i].id == expanded { await loadVolumes(&newGroups[i]) }
            }
            groups = newGroups.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            error = nil
            for h in householdHosts.indices where favorites[h] == nil {
                favorites[h] = (try? await loadFavorites(householdHosts[h])) ?? []
            }
        } catch {
            if !rediscover { await refresh(rediscover: true) } else { self.error = error.localizedDescription }
        }
    }

    /// Reads rooms and groups from each Sonos system on the network.
    private func loadTopology() async throws -> [ZoneGroup] {
        var covered = Set<String>()
        var result: [ZoneGroup] = []
        var households: [String] = []

        for host in householdHosts where !covered.contains(host) {
            let reply = try await SonosAPI.call(host, .topology, "GetZoneGroupState")
            guard let state = reply.value("ZoneGroupState"),
                  let tree = XMLTree.parse(Data(state.utf8)) else { continue }
            let household = households.count
            households.append(host)

            // Every device with a Location (including subs, surrounds, and hidden members) belongs to this system.
            for node in tree.all("ZoneGroupMember") + tree.all("Satellite") {
                if let h = hostOf(node.attrs["Location"]) { covered.insert(h) }
            }

            for g in tree.all("ZoneGroup") {
                guard let coord = g.attrs["Coordinator"] else { continue }
                let rooms: [Room] = g.children.compactMap { m in
                    guard m.name == "ZoneGroupMember", m.attrs["Invisible"] != "1", m.attrs["IsZoneBridge"] != "1",
                          let id = m.attrs["UUID"], let name = m.attrs["ZoneName"], let h = hostOf(m.attrs["Location"]) else { return nil }
                    return Room(id: id, name: name, host: h)
                }
                if !rooms.isEmpty { result.append(ZoneGroup(id: coord, household: household, rooms: rooms)) }
            }
        }
        householdHosts = households
        return result
    }

    private func hostOf(_ location: String?) -> String? {
        guard let location, let url = URL(string: location), let h = url.host else { return nil }
        return "\(h):\(url.port ?? 1400)"
    }

    private func loadPlayback(_ group: inout ZoneGroup) async {
        let host = group.coordinator.host
        let transport = try? await SonosAPI.call(host, .avTransport, "GetTransportInfo", [SonosAPI.instance])
        group.state = transport?.value("CurrentTransportState") ?? ""

        let position = try? await SonosAPI.call(host, .avTransport, "GetPositionInfo", [SonosAPI.instance])
        let trackURI = position?.value("TrackURI") ?? ""
        let track = SonosAPI.didl(position?.value("TrackMetaData"), host: host)

        let media = try? await SonosAPI.call(host, .avTransport, "GetMediaInfo", [SonosAPI.instance])
        let source = SonosAPI.didl(media?.value("CurrentURIMetaData"), host: host)

        if trackURI.hasSuffix(MacAudioStreamer.path) {
            group.title = "Mac audio"
            group.subtitle = nil
        } else if trackURI.hasPrefix("x-sonos-htastream") {
            group.title = "TV"
            group.subtitle = nil
        } else if trackURI.hasPrefix("x-rincon-stream") {
            group.title = "Line-In"
            group.subtitle = nil
        } else if let stream = track?.stream, !stream.isEmpty {
            // Radio: the station sends the current song as "streamContent".
            group.title = stream
            group.subtitle = source?.title ?? track?.title
        } else {
            let title = track?.title.flatMap { $0.hasPrefix("x-") ? nil : $0 }
            group.title = title ?? source?.title
            group.subtitle = title == nil ? nil : track?.artist
        }
        group.art = track?.art ?? source?.art
    }

    private func loadVolumes(_ group: inout ZoneGroup) async {
        let host = group.coordinator.host
        _ = try? await SonosAPI.call(host, .groupRendering, "SnapshotGroupVolume", [SonosAPI.instance])
        let gv = try? await SonosAPI.call(host, .groupRendering, "GetGroupVolume", [SonosAPI.instance])
        group.volume = gv?.value("CurrentVolume").flatMap(Int.init)
        for i in group.rooms.indices {
            let v = try? await SonosAPI.call(group.rooms[i].host, .rendering, "GetVolume", [SonosAPI.instance, ("Channel", "Master")])
            group.rooms[i].volume = v?.value("CurrentVolume").flatMap(Int.init)
        }
    }

    private func loadFavorites(_ host: String) async throws -> [Favorite] {
        let reply = try await SonosAPI.call(host, .content, "Browse", [
            ("ObjectID", "FV:2"), ("BrowseFlag", "BrowseDirectChildren"), ("Filter", "*"),
            ("StartingIndex", "0"), ("RequestedCount", "200"), ("SortCriteria", ""),
        ])
        guard let result = reply.value("Result"), let tree = XMLTree.parse(Data(result.utf8)) else { return [] }
        return tree.all("item").compactMap { item in
            guard let title = item.value("dc:title"), let uri = item.value("res") else { return nil }
            let meta = item.value("r:resMD") ?? ""
            let cls = SonosAPI.didl(meta, host: host)?.itemClass ?? ""
            return Favorite(
                id: item.attrs["id"] ?? title, title: title, uri: uri, meta: meta,
                art: SonosAPI.artURL(item.value("upnp:albumArtURI"), host: host),
                isStation: cls.contains("audioBroadcast")
            )
        }
    }

    // MARK: Actions

    private func run(_ work: () async throws -> Void) async {
        do {
            try await work()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await refresh()
    }

    /// The panel shows the addresses it saw when it was last open until its first refresh finishes, and
    /// speakers can come back on new ones (say, after a power cut). Read them again before acting.
    private func current(_ group: ZoneGroup) async -> ZoneGroup {
        guard let fresh = try? await loadTopology().first(where: { $0.id == group.id }) else { return group }
        var group = group
        group.rooms = fresh.rooms
        return group
    }

    func togglePlay(_ group: ZoneGroup) async {
        let group = await current(group)
        if group.isPlaying && macAudioGroup == group.id {
            await toggleMacAudio(on: group)
            return
        }
        await run {
            let action = group.isPlaying ? "Pause" : "Play"
            var args = [SonosAPI.instance]
            if action == "Play" { args.append(("Speed", "1")) }
            try await SonosAPI.call(group.coordinator.host, .avTransport, action, args)
        }
    }

    func skip(_ group: ZoneGroup, forward: Bool) async {
        let group = await current(group)
        await run {
            try await SonosAPI.call(group.coordinator.host, .avTransport, forward ? "Next" : "Previous", [SonosAPI.instance])
        }
    }

    func setGroupVolume(_ group: ZoneGroup, _ volume: Int) async {
        let host = group.coordinator.host
        _ = try? await SonosAPI.call(host, .groupRendering, "SnapshotGroupVolume", [SonosAPI.instance])
        _ = try? await SonosAPI.call(host, .groupRendering, "SetGroupVolume", [SonosAPI.instance, ("DesiredVolume", String(volume))])
    }

    func setRoomVolume(_ room: Room, _ volume: Int) async {
        _ = try? await SonosAPI.call(room.host, .rendering, "SetVolume", [SonosAPI.instance, ("Channel", "Master"), ("DesiredVolume", String(volume))])
    }

    /// Adds a room to this group, or takes it out if it's already in it.
    func toggleRoom(_ room: Room, in group: ZoneGroup) async {
        await run {
            if group.rooms.contains(where: { $0.id == room.id }) {
                try await SonosAPI.call(room.host, .avTransport, "BecomeCoordinatorOfStandaloneGroup", [SonosAPI.instance])
            } else {
                try await SonosAPI.call(room.host, .avTransport, "SetAVTransportURI", [
                    SonosAPI.instance, ("CurrentURI", "x-rincon:\(group.id)"), ("CurrentURIMetaData", ""),
                ])
            }
        }
    }

    func play(_ favorite: Favorite, on group: ZoneGroup) async {
        let group = await current(group)
        await run {
            let host = group.coordinator.host
            if favorite.isStation {
                try await SonosAPI.call(host, .avTransport, "SetAVTransportURI", [
                    SonosAPI.instance, ("CurrentURI", favorite.uri), ("CurrentURIMetaData", favorite.meta),
                ])
            } else {
                // Albums, playlists, and tracks go through the queue.
                try await SonosAPI.call(host, .avTransport, "RemoveAllTracksFromQueue", [SonosAPI.instance])
                try await SonosAPI.call(host, .avTransport, "AddURIToQueue", [
                    SonosAPI.instance, ("EnqueuedURI", favorite.uri), ("EnqueuedURIMetaData", favorite.meta),
                    ("DesiredFirstTrackNumberEnqueued", "0"), ("EnqueueAsNext", "0"),
                ])
                try await SonosAPI.call(host, .avTransport, "SetAVTransportURI", [
                    SonosAPI.instance, ("CurrentURI", "x-rincon-queue:\(group.id)#0"), ("CurrentURIMetaData", ""),
                ])
            }
            try await SonosAPI.call(host, .avTransport, "Play", [SonosAPI.instance, ("Speed", "1")])
        }
    }

    /// Sends everything the Mac is playing to this group, or stops if it's already doing that.
    func toggleMacAudio(on group: ZoneGroup) async {
        let group = await current(group)
        let host = group.coordinator.host
        if macAudioGroup == group.id {
            stopMacAudio("stopped from Sonos Bar")
            await run { try await SonosAPI.call(host, .avTransport, "Stop", [SonosAPI.instance]) }
            return
        }
        await run {
            let uri = try await streamer.start(reachableFrom: host)
            macAudioGroup = group.id
            let meta = """
            <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"><item id="R:0/0/0" parentID="R:0/0" restricted="true"><dc:title>Mac audio</dc:title><upnp:class>object.item.audioItem.audioBroadcast</upnp:class><desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">SA_RINCON65031_</desc></item></DIDL-Lite>
            """
            do {
                // Switch to the volume Mac audio had last time (38 the first time), remembering the current one.
                // If the speakers are still on the Mac stream (the app was restarted mid-session), the current
                // volume is already the Mac one, so keep the volume saved when the session first started.
                let position = try? await SonosAPI.call(host, .avTransport, "GetPositionInfo", [SonosAPI.instance])
                let resuming = position?.value("TrackURI")?.hasSuffix(MacAudioStreamer.path) == true && volumeBeforeMac != nil
                macAudioHost = host
                if !resuming {
                    let current = try? await SonosAPI.call(host, .groupRendering, "GetGroupVolume", [SonosAPI.instance])
                    volumeBeforeMac = current?.value("CurrentVolume").flatMap(Int.init)
                    let saved = UserDefaults.standard.object(forKey: Self.macVolumeKey) as? Int ?? 38
                    await setGroupVolume(group, saved)
                }
                try await SonosAPI.call(host, .avTransport, "SetAVTransportURI", [
                    SonosAPI.instance, ("CurrentURI", uri), ("CurrentURIMetaData", meta),
                ])
                try await SonosAPI.call(host, .avTransport, "Play", [SonosAPI.instance, ("Speed", "1")])
            } catch {
                stopMacAudio("couldn't start: \(error.localizedDescription)")
                throw error
            }
            MacAudioStreamer.log("playing Mac audio on \(group.name)")
            watchMacAudio(host: host)
        }
    }

    /// Every few seconds: if the speakers dropped the stream, press Play again; if they've moved on to
    /// something else, stop capturing so the Mac's own sound comes back. Runs with the panel closed too.
    private func watchMacAudio(host: String) {
        macAudioWatch?.cancel()
        macAudioWatch = Task {
            var misses = 0
            var lastRestart = Date.distantPast
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                guard let position = try? await SonosAPI.call(host, .avTransport, "GetPositionInfo", [SonosAPI.instance]),
                      let transport = try? await SonosAPI.call(host, .avTransport, "GetTransportInfo", [SonosAPI.instance]) else {
                    continue // speaker didn't answer this time; try again next round
                }
                let uri = position.value("TrackURI") ?? ""
                let state = transport.value("CurrentTransportState") ?? ""
                if !uri.hasSuffix(MacAudioStreamer.path) {
                    // Only give up after two checks in a row, so one odd answer can't cut the music.
                    misses += 1
                    if misses >= 2 { stopMacAudio("speakers switched to \(uri.isEmpty ? "nothing" : uri)"); return }
                    continue
                }
                misses = 0
                if state == "STOPPED" {
                    // Stopped again right after a restart: someone is pausing it on purpose, so let it be.
                    if Date().timeIntervalSince(lastRestart) < 60 { stopMacAudio("stopped again after a restart"); return }
                    lastRestart = Date()
                    MacAudioStreamer.log("speakers stopped the stream, pressing Play")
                    _ = try? await SonosAPI.call(host, .avTransport, "Play", [SonosAPI.instance, ("Speed", "1")])
                }
            }
        }
    }

    private func stopMacAudio(_ reason: String) {
        MacAudioStreamer.log("stopping Mac audio: \(reason)")
        macAudioWatch?.cancel()
        macAudioWatch = nil
        streamer.stop()
        macAudioGroup = nil
        restoreVolumeAfterMac()
    }

    /// Saves where the volume ended up for next time, then puts back the volume from before Mac audio.
    private func restoreVolumeAfterMac() {
        guard let host = macAudioHost else { return }
        let before = volumeBeforeMac
        macAudioHost = nil
        volumeBeforeMac = nil
        Task {
            let current = try? await SonosAPI.call(host, .groupRendering, "GetGroupVolume", [SonosAPI.instance])
            if let macVolume = current?.value("CurrentVolume").flatMap(Int.init) {
                UserDefaults.standard.set(macVolume, forKey: Self.macVolumeKey)
            }
            guard let before else { return }
            _ = try? await SonosAPI.call(host, .groupRendering, "SnapshotGroupVolume", [SonosAPI.instance])
            _ = try? await SonosAPI.call(host, .groupRendering, "SetGroupVolume", [SonosAPI.instance, ("DesiredVolume", String(before))])
            MacAudioStreamer.log("volume back to \(before) (Mac audio was at \(current?.value("CurrentVolume") ?? "?"))")
        }
    }
}
