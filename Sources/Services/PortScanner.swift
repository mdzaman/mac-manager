import Foundation

/// Lists the ports currently listening on this Mac, and which process owns each.
///
/// `lsof` only reports processes the current user can see, so ports owned by
/// other users or by root appear without detail unless the app is run with
/// elevated privileges. That limitation is surfaced in the UI rather than
/// papered over.
final class PortScanner: ObservableObject {

    @Published private(set) var entries: [PortEntry] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastError: String?

    private let work = DispatchQueue(label: "com.macmanager.ports", qos: .userInitiated)
    private var timer: Timer?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        if isScanning { return }
        isScanning = true

        work.async {
            let found = PortScanner.listListeningPorts()
            DispatchQueue.main.async {
                self.entries = found
                self.isScanning = false
                self.lastError = found.isEmpty ? "No listening ports found." : nil
            }
        }
    }

    /// `-nP` keeps addresses and ports numeric; `+c 0` stops lsof truncating
    /// the command name to nine characters.
    ///
    /// One process listening on both IPv4 and IPv6 is a single fact, so
    /// bindings are merged per process-and-port and the widest scope wins.
    static func listListeningPorts() -> [PortEntry] {
        let result = Shell.run("/usr/sbin/lsof",
                               ["-nP", "+c", "0", "-iTCP", "-sTCP:LISTEN"])

        struct Binding {
            let command: String
            let user: String
            let address: String
            let isIPv6: Bool
        }
        var bindings: [String: [Binding]] = [:]
        var order: [String] = []

        for (index, rawLine) in result.out.components(separatedBy: .newlines).enumerated() {
            if index == 0 { continue }  // header
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
            let fields = line.whitespaceFields
            if fields.count < 9 { continue }

            guard let pid = Int32(fields[1]) else { continue }
            let type = fields[4]                   // IPv4 / IPv6
            let name = fields[fields.count - 2]    // NAME sits before "(LISTEN)"

            guard let parsed = parseAddress(name) else { continue }

            let key = "\(pid)-\(parsed.port)"
            if bindings[key] == nil { order.append(key) }
            bindings[key, default: []].append(
                Binding(command: unescape(fields[0]),
                        user: fields[2],
                        address: parsed.address,
                        isIPv6: type == "IPv6"))
        }

        var found: [PortEntry] = []
        for key in order {
            guard let group = bindings[key], let first = group.first else { continue }
            let parts = key.components(separatedBy: "-")
            guard parts.count == 2, let pid = Int32(parts[0]), let port = Int(parts[1]) else { continue }

            // If any binding reaches every interface, the port is exposed —
            // a localhost-only sibling does not make it safe.
            let widest = group.first { isWildcard($0.address) } ?? first
            let hasIPv6 = group.contains { $0.isIPv6 }
            let hasIPv4 = group.contains { !$0.isIPv6 }
            let proto = (hasIPv4 && hasIPv6) ? "TCP · IPv4 and IPv6" : (hasIPv6 ? "TCP · IPv6" : "TCP")

            found.append(PortEntry(port: port,
                                   networkProtocol: proto,
                                   address: widest.address,
                                   pid: pid,
                                   processName: first.command,
                                   user: first.user))
        }

        return found.sorted { lhs, rhs in
            if lhs.port != rhs.port { return lhs.port < rhs.port }
            return lhs.processName < rhs.processName
        }
    }

    private static func isWildcard(_ address: String) -> Bool {
        return address == "*" || address == "0.0.0.0" || address == "::"
    }

    /// lsof escapes non-printing and space characters as `\xNN`, so
    /// "LM\x20Studio" has to be turned back into "LM Studio" for display.
    static func unescape(_ text: String) -> String {
        if !text.contains("\\x") { return text }

        var out = ""
        var rest = Substring(text)
        while let range = rest.range(of: "\\x") {
            out += rest[rest.startIndex ..< range.lowerBound]
            let afterMarker = range.upperBound
            let hex = rest[afterMarker...].prefix(2)
            if hex.count == 2, let value = UInt8(hex, radix: 16), let scalar = Unicode.Scalar(UInt32(value)) {
                out.append(Character(scalar))
                rest = rest[rest.index(afterMarker, offsetBy: 2)...]
            } else {
                out += "\\x"
                rest = rest[afterMarker...]
            }
        }
        out += rest
        return out
    }

    /// Splits "127.0.0.1:5432", "*:7000" or "[::1]:8080" into address and port.
    private static func parseAddress(_ text: String) -> (address: String, port: Int)? {
        guard let colon = text.lastIndex(of: ":") else { return nil }
        guard let port = Int(text[text.index(after: colon)...]) else { return nil }

        var address = String(text[text.startIndex ..< colon])
        if address.hasPrefix("["), address.hasSuffix("]") {
            address = String(address.dropFirst().dropLast())
        }
        if address.isEmpty { address = "*" }
        return (address, port)
    }

    /// Full executable path for a pid, used to show where a process came from.
    static func executablePath(pid: Int32) -> String {
        let result = Shell.run("/bin/ps", ["-p", "\(pid)", "-o", "comm="])
        return result.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
