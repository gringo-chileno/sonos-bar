import Foundation

// Sonos speakers accept UPnP/SOAP commands on port 1400. This works the same on S1 and S2.

enum Service {
    case avTransport, rendering, groupRendering, topology, content

    var path: String {
        switch self {
        case .avTransport: "/MediaRenderer/AVTransport/Control"
        case .rendering: "/MediaRenderer/RenderingControl/Control"
        case .groupRendering: "/MediaRenderer/GroupRenderingControl/Control"
        case .topology: "/ZoneGroupTopology/Control"
        case .content: "/MediaServer/ContentDirectory/Control"
        }
    }

    var urn: String {
        switch self {
        case .avTransport: "urn:schemas-upnp-org:service:AVTransport:1"
        case .rendering: "urn:schemas-upnp-org:service:RenderingControl:1"
        case .groupRendering: "urn:schemas-upnp-org:service:GroupRenderingControl:1"
        case .topology: "urn:schemas-upnp-org:service:ZoneGroupTopology:1"
        case .content: "urn:schemas-upnp-org:service:ContentDirectory:1"
        }
    }
}

struct SonosError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum SonosAPI {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    @discardableResult
    static func call(_ host: String, _ service: Service, _ action: String, _ args: [(String, String)] = []) async throws -> XNode {
        let body = args.map { "<\($0.0)>\(escape($0.1))</\($0.0)>" }.joined()
        let envelope = """
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:\(action) xmlns:u="\(service.urn)">\(body)</u:\(action)></s:Body></s:Envelope>
        """
        var req = URLRequest(url: URL(string: "http://\(host)\(service.path)")!, timeoutInterval: 4)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(service.urn)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        req.httpBody = Data(envelope.utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        let tree = XMLTree.parse(data)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let code = tree?.first("errorCode")?.text ?? "?"
            throw SonosError(message: "\(action) failed (error \(code))")
        }
        guard let result = tree?.first(where: { $0.name.hasSuffix("\(action)Response") }) else {
            throw SonosError(message: "\(action): unreadable reply")
        }
        return result
    }

    static let instance = ("InstanceID", "0")

    // MARK: Discovery

    /// Sends an SSDP search and returns "ip:1400" for every Sonos speaker that answers.
    static func discover(seconds: Double = 2) -> [String] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(1900).bigEndian
        addr.sin_addr.s_addr = inet_addr("239.255.255.250")

        let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: urn:schemas-upnp-org:device:ZonePlayer:1\r\n\r\n"
        for _ in 0..<2 {
            _ = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    msg.withCString { sendto(fd, $0, strlen($0), 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            }
        }

        var hosts = Set<String>()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { continue }
            let text = String(decoding: buffer[0..<n], as: UTF8.self)
            for line in text.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("location:") {
                let value = line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces)
                if let url = URL(string: value), let h = url.host, text.contains("Sonos") {
                    hosts.insert("\(h):\(url.port ?? 1400)")
                }
            }
        }
        return Array(hosts)
    }

    // MARK: Metadata

    struct TrackInfo {
        var title: String?
        var artist: String?
        var art: String?
        var stream: String?
        var itemClass: String?
    }

    /// Reads the first item or container in a DIDL-Lite metadata string.
    static func didl(_ xml: String?, host: String) -> TrackInfo? {
        guard let xml, !xml.isEmpty, xml != "NOT_IMPLEMENTED",
              let tree = XMLTree.parse(Data(xml.utf8)),
              let item = tree.first("item") ?? tree.first("container") else { return nil }
        return TrackInfo(
            title: item.value("dc:title"),
            artist: item.value("dc:creator"),
            art: artURL(item.value("upnp:albumArtURI"), host: host),
            stream: item.value("r:streamContent"),
            itemClass: item.value("upnp:class")
        )
    }

    static func artURL(_ uri: String?, host: String) -> String? {
        guard let uri, !uri.isEmpty else { return nil }
        return uri.hasPrefix("/") ? "http://\(host)\(uri)" : uri
    }
}

// MARK: - Tiny XML tree

final class XNode {
    let name: String
    let attrs: [String: String]
    var children: [XNode] = []
    var text = ""

    init(_ name: String, _ attrs: [String: String]) {
        self.name = name
        self.attrs = attrs
    }

    func first(where match: (XNode) -> Bool) -> XNode? {
        for c in children {
            if match(c) { return c }
            if let found = c.first(where: match) { return found }
        }
        return nil
    }

    func first(_ name: String) -> XNode? { first { $0.name == name } }

    func all(_ name: String) -> [XNode] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.all(name) }
    }

    func value(_ name: String) -> String? {
        guard let t = children.first(where: { $0.name == name })?.text, !t.isEmpty else { return nil }
        return t
    }
}

final class XMLTree: NSObject, XMLParserDelegate {
    private let root = XNode("#root", [:])
    private lazy var stack = [root]

    static func parse(_ data: Data) -> XNode? {
        let tree = XMLTree()
        let parser = XMLParser(data: data)
        parser.delegate = tree
        return parser.parse() ? tree.root : nil
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let node = XNode(name, attributes)
        stack.last?.children.append(node)
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        stack.removeLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }
}
