import SwiftUI

@main
struct SonosBarApp: App {
    @State private var model = SonosModel()

    var body: some Scene {
        MenuBarExtra("Sonos", systemImage: "hifispeaker.2.fill") {
            ContentView()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    @Environment(SonosModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sonos").font(.headline)
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button {
                    Task { await model.refresh(rediscover: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Search for speakers again")
            }
            .padding(12)

            Divider()

            if let error = model.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(12)
            }

            ScrollView {
                VStack(spacing: 4) {
                    if model.groups.isEmpty && model.error == nil {
                        Text("Looking for speakers…")
                            .foregroundStyle(.secondary)
                            .padding(20)
                    }
                    ForEach(model.groups) { group in
                        GroupRow(group: group)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 560)

            Divider()

            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
            }
            .padding(10)
        }
        .frame(width: 360)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}

struct GroupRow: View {
    @Environment(SonosModel.self) private var model
    let group: ZoneGroup

    private var isExpanded: Bool { model.expanded == group.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Artwork(url: group.art, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(group.title ?? "—")
                        .font(.callout)
                        .lineLimit(1)
                    if let subtitle = group.subtitle {
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button {
                    Task { await model.togglePlay(group) }
                } label: {
                    Image(systemName: group.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
                .help(group.isPlaying ? "Pause" : "Play")
            }
            .contentShape(Rectangle())
            .onTapGesture {
                model.expanded = isExpanded ? nil : group.id
                Task { await model.refresh() }
            }

            if isExpanded {
                GroupDetail(group: group)
            }
        }
        .padding(10)
        .background(isExpanded ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct GroupDetail: View {
    @Environment(SonosModel.self) private var model
    let group: ZoneGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 28) {
                Spacer()
                Button { Task { await model.skip(group, forward: false) } } label: {
                    Image(systemName: "backward.fill")
                }
                .help("Previous")
                Button { Task { await model.togglePlay(group) } } label: {
                    Image(systemName: group.isPlaying ? "pause.fill" : "play.fill")
                }
                .help(group.isPlaying ? "Pause" : "Play")
                Button { Task { await model.skip(group, forward: true) } } label: {
                    Image(systemName: "forward.fill")
                }
                .help("Next")
                Spacer()
            }
            .font(.title3)
            .buttonStyle(.borderless)

            VolumeSlider(label: group.rooms.count > 1 ? "All" : group.name, value: group.volume) { v in
                await model.setGroupVolume(group, v)
            }
            if group.rooms.count > 1 {
                ForEach(group.rooms) { room in
                    VolumeSlider(label: room.name, value: room.volume) { v in
                        await model.setRoomVolume(room, v)
                    }
                }
            }

            SectionTitle("Rooms")
            ForEach(model.allRooms.filter { room in
                model.groups.first { $0.rooms.contains(room) }?.household == group.household
            }) { room in
                let inGroup = group.rooms.contains { $0.id == room.id }
                Button {
                    Task { await model.toggleRoom(room, in: group) }
                } label: {
                    HStack {
                        Image(systemName: inGroup ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(inGroup ? Color.accentColor : .secondary)
                        Text(room.name)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(inGroup && room.id == group.id && group.rooms.count > 1)
                .help(inGroup ? "Remove from this group" : "Add to this group")
            }

            SectionTitle("Favorites")
            let favorites = model.favorites[group.household] ?? []
            if favorites.isEmpty {
                Text("—").foregroundStyle(.secondary)
            }
            ForEach(favorites) { fav in
                Button {
                    Task { await model.play(fav, on: group) }
                } label: {
                    HStack(spacing: 8) {
                        Artwork(url: fav.art, size: 28)
                        Text(fav.title).lineLimit(1)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }
}

struct VolumeSlider: View {
    let label: String
    let value: Int?
    let onChange: (Int) async -> Void

    @State private var local: Double = 0
    @State private var editing = false
    @State private var pending: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.callout)
                .lineLimit(1)
                .frame(width: 90, alignment: .leading)
            Slider(value: $local, in: 0...100) { isEditing in
                editing = isEditing
                if !isEditing { send() }
            }
            .disabled(value == nil)
            Text(value == nil ? "—" : "\(Int(local))")
                .font(.callout.monospacedDigit())
                .frame(width: 28, alignment: .trailing)
        }
        .onAppear { local = Double(value ?? 0) }
        .onChange(of: value) { _, new in
            if !editing, let new { local = Double(new) }
        }
        .onChange(of: local) { _, _ in
            if editing { send(debounce: true) }
        }
    }

    private func send(debounce: Bool = false) {
        pending?.cancel()
        let v = Int(local)
        pending = Task {
            if debounce { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            await onChange(v)
        }
    }
}

struct Artwork: View {
    let url: String?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Image(systemName: "music.note")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.08))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
