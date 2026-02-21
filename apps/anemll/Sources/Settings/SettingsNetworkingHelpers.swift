import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct SettingsHostPort: Equatable {
    var host: String
    var port: Int
}

enum SettingsNetworkingHelpers {
    static func parseHostPort(from address: String) -> SettingsHostPort? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("["),
           let close = trimmed.firstIndex(of: "]"),
           close < trimmed.endIndex
        {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let portStart = trimmed.index(after: close)
            guard portStart < trimmed.endIndex, trimmed[portStart] == ":" else { return nil }
            let portString = String(trimmed[trimmed.index(after: portStart)...])
            guard let port = Int(portString) else { return nil }
            return SettingsHostPort(host: host, port: port)
        }

        guard let colon = trimmed.lastIndex(of: ":") else { return nil }
        let host = String(trimmed[..<colon])
        let portString = String(trimmed[trimmed.index(after: colon)...])
        guard !host.isEmpty, let port = Int(portString) else { return nil }
        return SettingsHostPort(host: host, port: port)
    }

    static func httpURLString(host: String?, port: Int?, fallback: String) -> String {
        if let host, let port {
            let needsBrackets = host.contains(":") && !host.hasPrefix("[") && !host.hasSuffix("]")
            let hostPart = needsBrackets ? "[\(host)]" : host
            return "http://\(hostPart):\(port)"
        }
        return "http://\(fallback)"
    }

    /// Extract a human-readable error from the nested gateway LLM error format.
    static func formatLLMError(_ raw: String) -> String {
        var httpStatus: String?
        if let statusRange = raw.range(of: "status: "),
           let commaRange = raw[statusRange.upperBound...].range(of: ",")
        {
            httpStatus = String(raw[statusRange.upperBound..<commaRange.lowerBound])
        }

        if let jsonStart = raw.range(of: "message: \"")?.upperBound ?? raw.range(of: "message:\"")?.upperBound {
            let tail = raw[jsonStart...]
            var jsonString = String(tail)
            if jsonString.hasSuffix("\")") {
                jsonString = String(jsonString.dropLast(2))
            } else if jsonString.hasSuffix("\"") {
                jsonString = String(jsonString.dropLast(1))
            }
            jsonString = jsonString.replacingOccurrences(of: "\\\"", with: "\"")

            if let data = jsonString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                if let errorObj = json["error"] as? [String: Any],
                   let msg = errorObj["message"] as? String
                {
                    if let status = httpStatus { return "HTTP \(status): \(msg)" }
                    return msg
                }
                if let msg = json["message"] as? String {
                    if let status = httpStatus { return "HTTP \(status): \(msg)" }
                    return msg
                }
            }
        }

        var cleaned = raw
        for prefix in ["local llm failed: ", "httpError(", "local llm "] {
            if cleaned.hasPrefix(prefix) { cleaned = String(cleaned.dropFirst(prefix.count)) }
        }
        if cleaned.hasSuffix(")") { cleaned = String(cleaned.dropLast(1)) }
        return cleaned
    }

    static func hasTailnetIPv4() -> Bool {
        var addrList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrList) == 0, let first = addrList else { return false }
        defer { freeifaddrs(addrList) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            let family = ptr.pointee.ifa_addr.pointee.sa_family
            if !isUp || isLoopback || family != UInt8(AF_INET) { continue }

            var addr = ptr.pointee.ifa_addr.pointee
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                &addr,
                socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST)
            guard result == 0 else { continue }
            let len = buffer.prefix { $0 != 0 }
            let bytes = len.map { UInt8(bitPattern: $0) }
            guard let ip = String(bytes: bytes, encoding: .utf8) else { continue }
            if self.isTailnetIPv4(ip) { return true }
        }

        return false
    }

    static func isTailnetHostOrIP(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasSuffix(".ts.net") || trimmed.hasSuffix(".ts.net.") {
            return true
        }
        return self.isTailnetIPv4(trimmed)
    }

    static func isTailnetIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        let a = octets[0]
        let b = octets[1]
        guard (0...255).contains(a), (0...255).contains(b) else { return false }
        return a == 100 && b >= 64 && b <= 127
    }
}
