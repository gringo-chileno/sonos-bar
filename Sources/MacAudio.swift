import AudioToolbox
import CoreAudio
import Foundation
import Network

// Streams everything the Mac is playing to Sonos as an MP3 "radio station".
// A Core Audio process tap captures system audio (and mutes the Mac's own speakers while it runs),
// ffmpeg encodes it to MP3, and a tiny HTTP server hands that stream to any speaker that asks.

final class MacAudioStreamer {
    static let path = "/mac-audio.mp3"
    private static let ffmpeg = "/opt/homebrew/bin/ffmpeg"

    private let queue = DispatchQueue(label: "sonosbar.macaudio")
    // Capture gets its own queue so a slow network moment can't delay the audio.
    private let audioQueue = DispatchQueue(label: "sonosbar.macaudio.capture", qos: .userInteractive)
    private var silenceTimer: DispatchSourceTimer?
    private var lastAudio = DispatchTime.now()
    private var sampleRate = 48000.0
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var encoder: Process?
    private var encoderInput: FileHandle?
    private var listener: NWListener?
    private var clients: [NWConnection] = []

    private(set) var port: UInt16 = 0
    var isRunning: Bool { listener != nil }

    /// Starts capturing and serving. Returns the stream URL a speaker on `sonosHost`'s network can reach.
    func start(reachableFrom sonosHost: String) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: Self.ffmpeg) else {
            throw SonosError(message: "ffmpeg not found at \(Self.ffmpeg). Install it with: brew install ffmpeg")
        }
        guard let ip = Self.localIP(near: sonosHost) else {
            throw SonosError(message: "Couldn't find this Mac's address on the Sonos network.")
        }
        stop()
        do {
            try startServer()
            let rate = try startTap()
            try startEncoder(sampleRate: rate)
            try startCapture()
            port = try await waitForPort()
        } catch {
            stop()
            throw error
        }
        return "x-rincon-mp3radio://\(ip):\(port)\(Self.path)"
    }

    func stop() {
        silenceTimer?.cancel()
        silenceTimer = nil
        if let procID, deviceID != kAudioObjectUnknown {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        if deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(deviceID) }
        deviceID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)

        audioQueue.sync {
            try? encoderInput?.close()
            encoderInput = nil
        }
        encoder?.terminationHandler = nil
        encoder?.terminate()
        encoder = nil

        listener?.cancel()
        listener = nil
        queue.sync {
            clients.forEach { $0.cancel() }
            clients = []
        }
        port = 0
    }

    static func log(_ message: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/SonosBar.log")
        let line = Data("\(Date().formatted(.iso8601)) \(message)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    // MARK: Capture

    /// Creates a tap on all system audio and returns its sample rate.
    private func startTap() throws -> Double {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "create the audio tap")

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "read the tap format")

        let outputUID = try Self.defaultOutputUID()
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Sonos Bar Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &deviceID), "create the capture device")
        sampleRate = format.mSampleRate
        Self.log("capture started: \(Int(format.mSampleRate)) Hz, \(format.mChannelsPerFrame) ch, flags \(format.mFormatFlags)")
        return format.mSampleRate
    }

    private func startCapture() throws {
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, audioQueue) { [weak self] _, input, _, _, _ in
            guard let self else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            // The tap's stream comes after any input streams of the output device, so it's the last buffer.
            guard let buffer = buffers.last, let data = buffer.mData, buffer.mDataByteSize > 0 else { return }
            self.lastAudio = .now()
            self.encode(Data(bytes: data, count: Int(buffer.mDataByteSize)))
        }, "start capturing")
        try check(AudioDeviceStart(deviceID, procID), "start capturing")

        // If the Mac sends nothing for a moment (say, between videos), keep the stream going with
        // silence. A speaker that stops getting data gives up and stops playing.
        let timer = DispatchSource.makeTimerSource(queue: audioQueue)
        let tick = 0.1
        let silence = Data(count: Int(sampleRate * tick) * 2 * MemoryLayout<Float32>.size)
        timer.schedule(deadline: .now() + tick, repeating: tick)
        timer.setEventHandler { [weak self] in
            guard let self, DispatchTime.now().uptimeNanoseconds - self.lastAudio.uptimeNanoseconds > 200_000_000 else { return }
            self.encode(silence)
        }
        timer.resume()
        silenceTimer = timer
    }

    private func encode(_ samples: Data) {
        try? encoderInput?.write(contentsOf: samples)
    }

    // MARK: Encoding

    private func startEncoder(sampleRate: Double) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.ffmpeg)
        process.arguments = [
            "-hide_banner", "-loglevel", "error",
            "-f", "f32le", "-ar", String(Int(sampleRate)), "-ac", "2", "-i", "pipe:0",
            "-c:a", "libmp3lame", "-b:a", "256k", "-flush_packets", "1", "-f", "mp3", "pipe:1",
        ]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            self?.broadcast(chunk)
        }
        process.terminationHandler = { p in Self.log("encoder exited (status \(p.terminationStatus))") }
        // Writing to the encoder after it exits must not kill the app.
        signal(SIGPIPE, SIG_IGN)
        try process.run()
        encoder = process
        encoderInput = input.fileHandleForWriting
    }

    // MARK: HTTP server

    private func startServer() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.readRequest(connection, buffer: Data())
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func waitForPort() async throws -> UInt16 {
        for _ in 0..<50 {
            if let port = listener?.port?.rawValue, port != 0 { return port }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw SonosError(message: "Couldn't open a port for the audio stream.")
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self else { return }
            let buffer = buffer + (data ?? Data())
            guard let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") else {
                if done || error != nil { connection.cancel() } else { self.readRequest(connection, buffer: buffer) }
                return
            }
            let firstLine = request.prefix { $0 != "\r" }
            guard firstLine.contains(Self.path) else {
                connection.send(content: Data("HTTP/1.0 404 Not Found\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            let header = "HTTP/1.0 200 OK\r\nContent-Type: audio/mpeg\r\nCache-Control: no-cache\r\nicy-name: Mac audio\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in })
            if firstLine.hasPrefix("HEAD") {
                connection.cancel()
            } else {
                self.clients.append(connection)
                Self.log("speaker connected: \(connection.endpoint)")
            }
        }
    }

    private func broadcast(_ chunk: Data) {
        queue.async {
            self.clients.removeAll { $0.state == .cancelled || $0.state.isFailed }
            for client in self.clients {
                client.send(content: chunk, completion: .contentProcessed { error in
                    if let error {
                        Self.log("speaker dropped: \(client.endpoint) (\(error))")
                        client.cancel()
                    }
                })
            }
        }
    }

    // MARK: Helpers

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else {
            throw SonosError(message: "Couldn't \(what) (error \(status)). Check System Settings → Privacy & Security → Screen & System Audio Recording.")
        }
    }

    private static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            throw SonosError(message: "Couldn't find the Mac's audio output.")
        }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else {
            throw SonosError(message: "Couldn't find the Mac's audio output.")
        }
        return uid.takeRetainedValue() as String
    }

    /// This Mac's IPv4 address on the same subnet as the speaker.
    private static func localIP(near host: String) -> String? {
        let target = host.split(separator: ":").first.map(String.init) ?? host
        let prefix = target.split(separator: ".").prefix(3).joined(separator: ".") + "."
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        var fallback: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: name)
            if ip.hasPrefix(prefix) { return ip }
            if !ip.hasPrefix("127.") && fallback == nil { fallback = ip }
        }
        return fallback
    }
}

private extension NWConnection.State {
    var isFailed: Bool { if case .failed = self { true } else { false } }
}
