import Foundation

public struct GatewayLocalTelegramConfig: Sendable, Equatable {
    public let botToken: String
    public let defaultChatID: String

    public init(botToken: String, defaultChatID: String = "") {
        self.botToken = botToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.defaultChatID = defaultChatID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isConfigured: Bool {
        !self.botToken.isEmpty
    }

    public static let disabled = GatewayLocalTelegramConfig(botToken: "", defaultChatID: "")
}

/// Protocol for routing device-specific tool commands to the app target.
/// The shared package cannot import iOS frameworks (EventKit, Contacts,
/// CoreLocation, etc.), so the app target provides an implementation.
public protocol GatewayDeviceToolBridge: Sendable {
    func execute(command: String, params: GatewayJSONValue?) async -> GatewayLocalTooling.ToolResult
    func supportedCommands() -> [String]
}

public enum GatewayLocalTooling {
    public struct ToolResult: Sendable {
        public let payload: GatewayJSONValue
        public let error: String?

        public init(payload: GatewayJSONValue, error: String?) {
            self.payload = payload
            self.error = error
        }
    }

    private struct NetworkFetchParams: Codable {
        let url: String
        let timeoutMs: Int?
        let headers: [String: String]?
    }

    private struct WebFetchParams: Codable {
        let url: String
        let timeoutMs: Int?
        let headers: [String: String]?
        let maxChars: Int?
    }

    private struct WebRenderParams: Codable {
        let url: String?
        let timeoutMs: Int?
        let waitUntil: String?
        let maxChars: Int?
        let html: String?
        let text: String?
        let includeLinks: Bool?
    }

    private struct WebExtractParams: Codable {
        let url: String?
        let html: String?
        let text: String?
        let maxChars: Int?
        let includeLinks: Bool?
    }

    private struct ReadParams: Codable {
        let path: String
        let maxChars: Int?
    }

    private struct WriteParams: Codable {
        let path: String
        let content: String
    }

    private struct EditParams: Codable {
        let path: String
        let oldText: String
        let newText: String
        let replaceAll: Bool?
    }

    private struct LsParams: Codable {
        let path: String?
        let recursive: Bool?
    }

    private struct ApplyPatchParams: Codable {
        let input: String
    }

    private struct TelegramSendParams: Codable {
        let chatId: String?
        let to: String?
        let text: String
        let parseMode: String?
        let disableWebPagePreview: Bool?
        let disableNotification: Bool?
    }

    private enum ToolClass {
        case safe
        case file
        case device
        case unsupported
    }

    private enum PatchHunk {
        case add(path: String, lines: [String])
        case delete(path: String)
        case update(path: String, chunks: [PatchChunk])
    }

    private struct PatchChunk {
        let oldLines: [String]
        let newLines: [String]
    }

    static let safeCommands = [
        "time.now",
        "device.info",
        "network.fetch",
        "web.fetch",
        "web.render",
        "web.extract",
        "telegram.send",
    ]

    static let fileCommands = [
        "read",
        "write",
        "edit",
        "apply_patch",
        "ls",
    ]

    static let deviceCommands: [String] = [
        "reminders.list",
        "reminders.add",
        "calendar.events",
        "calendar.add",
        "contacts.search",
        "contacts.add",
        "location.get",
        "photos.latest",
        "camera.snap",
        "motion.activity",
        "motion.pedometer",
        "credentials.get",
        "credentials.set",
        "credentials.delete",
        "get_idle_time",
        "dream_mode",
    ]

    static var localCommands: [String] {
        self.safeCommands + self.fileCommands
    }

    static func supports(_ command: String) -> Bool {
        self.localCommands.contains(command) || self.deviceCommands.contains(command)
    }

    static func execute(
        command rawCommand: String,
        params: GatewayJSONValue?,
        hostLabel: String,
        workspaceRoot: URL?,
        urlSession: URLSession,
        upstreamForwarder: (any GatewayUpstreamForwarding)? = nil,
        telegramConfig: GatewayLocalTelegramConfig = .disabled,
        enableLocalSafeTools: Bool,
        enableLocalFileTools: Bool,
        enableLocalDeviceTools: Bool = false,
        deviceToolBridge: (any GatewayDeviceToolBridge)? = nil) async -> ToolResult
    {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            return ToolResult(payload: .null, error: "unknown local command")
        }
        guard Self.supports(command) else {
            return ToolResult(payload: .null, error: "unsupported local command: \(command)")
        }

        switch Self.classifyCommand(command) {
        case .safe:
            guard enableLocalSafeTools else {
                return ToolResult(payload: .null, error: "local safe tools are disabled")
            }
        case .file:
            guard enableLocalFileTools else {
                return ToolResult(payload: .null, error: "local file tools are disabled")
            }
            guard workspaceRoot != nil else {
                return ToolResult(payload: .null, error: "workspace root is unavailable")
            }
        case .device:
            guard enableLocalDeviceTools else {
                return ToolResult(payload: .null, error: "local device tools are disabled")
            }
            guard let bridge = deviceToolBridge else {
                return ToolResult(payload: .null, error: "device tool bridge unavailable")
            }
            return await bridge.execute(command: command, params: params)
        case .unsupported:
            return ToolResult(payload: .null, error: "unsupported local command: \(command)")
        }

        switch command {
        case "time.now":
            let nowMs = GatewayCore.currentTimestampMs()
            return ToolResult(
                payload: .object([
                    "ok": .bool(true),
                    "command": .string(command),
                    "ts": .integer(nowMs),
                    "iso8601": .string(
                        ISO8601DateFormatter()
                            .string(from: Date(timeIntervalSince1970: Double(nowMs) / 1000.0))),
                    "timezone": .string(TimeZone.current.identifier),
                    "hostLabel": .string(hostLabel),
                ]),
                error: nil)

        case "device.info":
            return ToolResult(
                payload: .object([
                    "ok": .bool(true),
                    "command": .string(command),
                    "hostLabel": .string(hostLabel),
                    "operatingSystemVersion": .string(ProcessInfo.processInfo.operatingSystemVersionString),
                    "isLowPowerModeEnabled": .bool(ProcessInfo.processInfo.isLowPowerModeEnabled),
                    "activeProcessorCount": .integer(Int64(ProcessInfo.processInfo.activeProcessorCount)),
                    "physicalMemory": .integer(Int64(ProcessInfo.processInfo.physicalMemory)),
                ]),
                error: nil)

        case "network.fetch":
            return await self.handleNetworkFetch(command: command, params: params, urlSession: urlSession)

        case "web.fetch":
            return await self.handleWebFetch(command: command, params: params, urlSession: urlSession)

        case "web.render":
            return await self.handleWebRender(
                command: command,
                params: params,
                upstreamForwarder: upstreamForwarder,
                urlSession: urlSession)

        case "web.extract":
            return await self.handleWebExtract(
                command: command,
                params: params,
                urlSession: urlSession)

        case "telegram.send":
            return await self.handleTelegramSend(
                command: command,
                params: params,
                urlSession: urlSession,
                telegramConfig: telegramConfig)

        case "read":
            guard let workspaceRoot else {
                return ToolResult(payload: .null, error: "workspace root is unavailable")
            }
            return self.handleRead(command: command, params: params, workspaceRoot: workspaceRoot)

        case "write":
            guard let workspaceRoot else {
                return ToolResult(payload: .null, error: "workspace root is unavailable")
            }
            return self.handleWrite(command: command, params: params, workspaceRoot: workspaceRoot)

        case "edit":
            guard let workspaceRoot else {
                return ToolResult(payload: .null, error: "workspace root is unavailable")
            }
            return self.handleEdit(command: command, params: params, workspaceRoot: workspaceRoot)

        case "apply_patch":
            guard let workspaceRoot else {
                return ToolResult(payload: .null, error: "workspace root is unavailable")
            }
            return self.handleApplyPatch(command: command, params: params, workspaceRoot: workspaceRoot)

        case "ls":
            guard let workspaceRoot else {
                return ToolResult(payload: .null, error: "workspace root is unavailable")
            }
            return self.handleLs(command: command, params: params, workspaceRoot: workspaceRoot)

        default:
            return ToolResult(payload: .null, error: "unsupported local command: \(command)")
        }
    }

    static func availableSafeCommands(upstreamConfigured: Bool) -> [String] {
        _ = upstreamConfigured
        return self.safeCommands
    }

    private static func classifyCommand(_ command: String) -> ToolClass {
        if self.safeCommands.contains(command) {
            return .safe
        }
        if self.fileCommands.contains(command) {
            return .file
        }
        if self.deviceCommands.contains(command) {
            return .device
        }
        return .unsupported
    }

    private static func handleNetworkFetch(
        command: String,
        params: GatewayJSONValue?,
        urlSession: URLSession) async -> ToolResult
    {
        guard let toolParams = GatewayPayloadCodec.decode(params, as: NetworkFetchParams.self) else {
            return ToolResult(payload: .null, error: "invalid network.fetch params")
        }
        guard let url = URL(string: toolParams.url) else {
            return ToolResult(payload: .null, error: "invalid network.fetch params: malformed url")
        }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            if let headers = toolParams.headers {
                for (key, value) in headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }
            let timeoutSeconds = max(1.0, Double(toolParams.timeoutMs ?? 5000) / 1000.0)
            request.timeoutInterval = min(timeoutSeconds, 30.0)
            let (data, response) = try await urlSession.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data.prefix(16384), encoding: .utf8)
            var responsePayload: [String: GatewayJSONValue] = [
                "ok": .bool(true),
                "command": .string(command),
                "url": .string(url.absoluteString),
                "statusCode": .integer(Int64(statusCode)),
                "bytes": .integer(Int64(data.count)),
            ]
            if let text {
                responsePayload["text"] = .string(text)
            } else {
                responsePayload["text"] = .null
            }
            return ToolResult(payload: .object(responsePayload), error: nil)
        } catch {
            return ToolResult(payload: .null, error: "network.fetch failed: \(error.localizedDescription)")
        }
    }

    private static func handleWebFetch(
        command: String,
        params: GatewayJSONValue?,
        urlSession: URLSession) async -> ToolResult
    {
        guard let toolParams = GatewayPayloadCodec.decode(params, as: WebFetchParams.self) else {
            return ToolResult(payload: .null, error: "invalid web.fetch params")
        }
        guard let url = URL(string: toolParams.url) else {
            return ToolResult(payload: .null, error: "invalid web.fetch params: malformed url")
        }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            if let headers = toolParams.headers {
                for (key, value) in headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }
            let timeoutSeconds = max(1.0, Double(toolParams.timeoutMs ?? 8000) / 1000.0)
            request.timeoutInterval = min(timeoutSeconds, 60.0)

            let (data, response) = try await urlSession.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let contentType = (response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Type")
            let rawText = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            let maxChars = max(512, min(toolParams.maxChars ?? 24000, 400_000))
            let clamped = self.clampText(rawText, maxChars: maxChars)

            var payload: [String: GatewayJSONValue] = [
                "ok": .bool(true),
                "command": .string(command),
                "url": .string(url.absoluteString),
                "statusCode": .integer(Int64(statusCode)),
                "bytes": .integer(Int64(data.count)),
                "text": .string(clamped.text),
                "chars": .integer(Int64(rawText.count)),
                "truncated": .bool(clamped.truncated),
            ]
            if let contentType {
                payload["contentType"] = .string(contentType)
            } else {
                payload["contentType"] = .null
            }
            if let response = response as? HTTPURLResponse {
                var headers: [String: GatewayJSONValue] = [:]
                for (key, value) in response.allHeaderFields {
                    headers[String(describing: key)] = .string(String(describing: value))
                }
                payload["headers"] = .object(headers)
            }
            return ToolResult(payload: .object(payload), error: nil)
        } catch {
            return ToolResult(payload: .null, error: "web.fetch failed: \(error.localizedDescription)")
        }
    }

    private static func handleWebRender(
        command: String,
        params: GatewayJSONValue?,
        upstreamForwarder: (any GatewayUpstreamForwarding)?,
        urlSession: URLSession) async -> ToolResult
    {
        guard let toolParams = GatewayPayloadCodec.decode(params, as: WebRenderParams.self) else {
            return ToolResult(payload: .null, error: "invalid web.render params")
        }
        let maxChars = max(512, min(toolParams.maxChars ?? 40000, 500_000))
        let includeLinks = toolParams.includeLinks ?? true
        let timeoutMs = max(1000, min(toolParams.timeoutMs ?? 20000, 120_000))

        let rawURL = toolParams.url?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURL = (rawURL?.isEmpty == false) ? rawURL : nil
        let requestURL: URL?
        if let normalizedURL {
            guard let parsedURL = URL(string: normalizedURL) else {
                return ToolResult(payload: .null, error: "invalid web.render params: malformed url")
            }
            requestURL = parsedURL
        } else {
            requestURL = nil
        }

        if let upstreamForwarder, let requestURL {
            var payload: [String: GatewayJSONValue] = [
                "url": .string(requestURL.absoluteString),
                "timeoutMs": .integer(Int64(timeoutMs)),
                "maxChars": .integer(Int64(maxChars)),
            ]
            if let waitUntil = toolParams.waitUntil?.trimmingCharacters(in: .whitespacesAndNewlines),
               !waitUntil.isEmpty
            {
                payload["waitUntil"] = .string(waitUntil)
            }

            let request = GatewayRequestFrame(
                id: "tvos-web-render-\(UUID().uuidString)",
                method: "web.render",
                params: .object(payload))

            do {
                let response = try await upstreamForwarder.forward(request)
                guard response.ok else {
                    let message = response.error?.message ?? "upstream web.render failed"
                    return ToolResult(payload: .null, error: "web.render upstream failed: \(message)")
                }
                guard let upstreamPayload = response.payload else {
                    return ToolResult(payload: .null, error: "web.render upstream failed: empty payload")
                }

                if var object = upstreamPayload.objectValue {
                    object["ok"] = .bool(true)
                    object["command"] = .string(command)
                    object["source"] = .string("upstream-render")
                    if object["url"] == nil {
                        object["url"] = .string(requestURL.absoluteString)
                    }
                    return ToolResult(payload: .object(object), error: nil)
                }

                return ToolResult(
                    payload: .object([
                        "ok": .bool(true),
                        "command": .string(command),
                        "source": .string("upstream-render"),
                        "url": .string(requestURL.absoluteString),
                        "payload": upstreamPayload,
                    ]),
                    error: nil)
            } catch {
                return ToolResult(payload: .null, error: "web.render failed: \(error.localizedDescription)")
            }
        }

        let renderSource: String
        let sourceKind: String
        if let html = toolParams.html?.trimmingCharacters(in: .whitespacesAndNewlines), !html.isEmpty {
            renderSource = html
            sourceKind = "html"
        } else if let text = toolParams.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            renderSource = text
            sourceKind = "text"
        } else if let requestURL {
            do {
                var request = URLRequest(url: requestURL)
                request.httpMethod = "GET"
                request.timeoutInterval = Double(timeoutMs) / 1000.0
                let (data, _) = try await urlSession.data(for: request)
                renderSource = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                sourceKind = self.looksLikeHTML(renderSource) ? "html" : "text"
            } catch {
                return ToolResult(payload: .null, error: "web.render fetch failed: \(error.localizedDescription)")
            }
        } else {
            return ToolResult(payload: .null, error: "invalid web.render params: provide url, html, or text")
        }

        let normalized = self.extractNormalizedContent(
            source: renderSource,
            sourceKind: sourceKind,
            baseURL: requestURL,
            includeLinks: includeLinks,
            maxChars: maxChars)
        let hydration = self.extractHydrationText(
            from: renderSource,
            maxChars: max(512, maxChars / 2))

        var mergedText = normalized.text
        if !hydration.text.isEmpty {
            if !mergedText.isEmpty {
                mergedText += "\n\n"
            }
            mergedText += hydration.text
        }
        let clampedText = self.clampText(mergedText, maxChars: maxChars)

        var metadata: [String: GatewayJSONValue] = [
            "renderer": .string("local-minimal"),
            "normalized": .bool(true),
            "hydrationSignals": .integer(Int64(hydration.signalCount)),
            "usedHydrationExtraction": .bool(!hydration.text.isEmpty),
            "sourceFormat": .string(sourceKind),
        ]
        if !hydration.signalNames.isEmpty {
            metadata["signals"] = .array(hydration.signalNames.map { .string($0) })
        }

        var payload: [String: GatewayJSONValue] = [
            "ok": .bool(true),
            "command": .string(command),
            "source": .string("local-minimal-render"),
            "title": normalized.title.map(GatewayJSONValue.string) ?? .null,
            "text": .string(clampedText.text),
            "chars": .integer(Int64(mergedText.count)),
            "truncated": .bool(clampedText.truncated || normalized.truncated),
            "linkCount": .integer(Int64(normalized.links.count)),
            "links": .array(normalized.links.map { link in
                .object([
                    "href": .string(link.href),
                    "text": .string(link.text),
                ])
            }),
            "metadata": .object(metadata),
        ]
        if let requestURL {
            payload["url"] = .string(requestURL.absoluteString)
        } else if let normalizedURL {
            payload["url"] = .string(normalizedURL)
        } else {
            payload["url"] = .null
        }
        return ToolResult(payload: .object(payload), error: nil)
    }

    private static func handleWebExtract(
        command: String,
        params: GatewayJSONValue?,
        urlSession: URLSession) async -> ToolResult
    {
        guard let toolParams = GatewayPayloadCodec.decode(params, as: WebExtractParams.self) else {
            return ToolResult(payload: .null, error: "invalid web.extract params")
        }
        let includeLinks = toolParams.includeLinks ?? true
        let maxChars = max(512, min(toolParams.maxChars ?? 20000, 400_000))

        var sourceURL: URL?
        var sourceText = ""
        var sourceKind = "text"

        if let html = toolParams.html?.trimmingCharacters(in: .whitespacesAndNewlines), !html.isEmpty {
            sourceText = html
            sourceKind = "html"
        } else if let text = toolParams.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            sourceText = text
            sourceKind = "text"
        } else if let rawURL = toolParams.url?.trimmingCharacters(in: .whitespacesAndNewlines), !rawURL.isEmpty {
            guard let url = URL(string: rawURL) else {
                return ToolResult(payload: .null, error: "invalid web.extract params: malformed url")
            }
            sourceURL = url
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = 20.0
                let (data, _) = try await urlSession.data(for: request)
                sourceText = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                sourceKind = self.looksLikeHTML(sourceText) ? "html" : "text"
            } catch {
                return ToolResult(payload: .null, error: "web.extract fetch failed: \(error.localizedDescription)")
            }
        } else {
            return ToolResult(payload: .null, error: "invalid web.extract params: provide html, text, or url")
        }

        let extracted = self.extractNormalizedContent(
            source: sourceText,
            sourceKind: sourceKind,
            baseURL: sourceURL,
            includeLinks: includeLinks,
            maxChars: maxChars)

        var payload: [String: GatewayJSONValue] = [
            "ok": .bool(true),
            "command": .string(command),
            "source": .string(sourceKind),
            "title": extracted.title.map(GatewayJSONValue.string) ?? .null,
            "text": .string(extracted.text),
            "chars": .integer(Int64(extracted.originalChars)),
            "truncated": .bool(extracted.truncated),
            "linkCount": .integer(Int64(extracted.links.count)),
            "links": .array(extracted.links.map { link in
                .object([
                    "href": .string(link.href),
                    "text": .string(link.text),
                ])
            }),
            "metadata": .object([
                "sourceFormat": .string(sourceKind),
                "normalized": .bool(true),
            ]),
        ]
        if let sourceURL {
            payload["url"] = .string(sourceURL.absoluteString)
        } else if let rawURL = toolParams.url?.trimmingCharacters(in: .whitespacesAndNewlines), !rawURL.isEmpty {
            payload["url"] = .string(rawURL)
        } else {
            payload["url"] = .null
        }
        return ToolResult(payload: .object(payload), error: nil)
    }

    private static func clampText(_ text: String, maxChars: Int) -> (text: String, truncated: Bool) {
        guard maxChars > 0, text.count > maxChars else {
            return (text, false)
        }
        return (String(text.prefix(maxChars)), true)
    }

    private static func looksLikeHTML(_ text: String) -> Bool {
        let sample = text.prefix(2048).lowercased()
        return sample.contains("<html")
            || sample.contains("<body")
            || sample.contains("<div")
            || sample.contains("<p>")
            || sample.contains("<article")
            || sample.contains("<main")
            || sample.contains("<a ")
    }

    private static func extractNormalizedContent(
        source: String,
        sourceKind: String,
        baseURL: URL?,
        includeLinks: Bool,
        maxChars: Int) -> (title: String?, text: String, originalChars: Int, truncated: Bool, links: [(
        href: String,
        text: String)])
    {
        let normalizedSource = source.replacingOccurrences(of: "\r\n", with: "\n")
        let extractedTitle: String?
        let extractedText: String
        let extractedLinks: [(href: String, text: String)]

        if sourceKind == "html" || self.looksLikeHTML(normalizedSource) {
            extractedTitle = self.extractHTMLTitle(normalizedSource)
            extractedLinks = includeLinks ? self.extractHTMLLinks(normalizedSource, baseURL: baseURL) : []
            let withoutScripts = self.replacingRegex(
                pattern: "<(script|style)[^>]*>[\\s\\S]*?</\\1>",
                in: normalizedSource,
                with: " ")
            let withoutTags = self.replacingRegex(
                pattern: "<[^>]+>",
                in: withoutScripts,
                with: " ")
            extractedText = self.normalizeWhitespace(self.decodeHTMLEntities(withoutTags))
        } else {
            extractedTitle = nil
            extractedLinks = []
            extractedText = self.normalizeWhitespace(self.decodeHTMLEntities(normalizedSource))
        }

        let clamped = self.clampText(extractedText, maxChars: maxChars)
        return (
            title: extractedTitle,
            text: clamped.text,
            originalChars: extractedText.count,
            truncated: clamped.truncated,
            links: Array(extractedLinks.prefix(40)))
    }

    private static func extractHTMLTitle(_ html: String) -> String? {
        let regex = try? NSRegularExpression(
            pattern: "<title[^>]*>(.*?)</title>",
            options: [.caseInsensitive, .dotMatchesLineSeparators])
        guard let regex,
              let match = regex.firstMatch(
                  in: html,
                  options: [],
                  range: NSRange(location: 0, length: html.utf16.count)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: html)
        else {
            return nil
        }
        let title = self.normalizeWhitespace(self.decodeHTMLEntities(String(html[range])))
        return title.isEmpty ? nil : title
    }

    private static func extractHTMLLinks(_ html: String, baseURL: URL?) -> [(href: String, text: String)] {
        let regex = try? NSRegularExpression(
            pattern: #"<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</a>"#,
            options: [.caseInsensitive])
        guard let regex else { return [] }

        let matches = regex.matches(
            in: html,
            options: [],
            range: NSRange(location: 0, length: html.utf16.count))
        var links: [(href: String, text: String)] = []
        var seen = Set<String>()
        for match in matches {
            guard match.numberOfRanges >= 3,
                  let hrefRange = Range(match.range(at: 1), in: html),
                  let labelRange = Range(match.range(at: 2), in: html)
            else {
                continue
            }
            let rawHref = html[hrefRange].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawHref.isEmpty else { continue }

            let resolvedHref: String = if let url = URL(string: rawHref, relativeTo: baseURL)?.absoluteURL {
                url.absoluteString
            } else {
                rawHref
            }
            guard !seen.contains(resolvedHref) else { continue }
            seen.insert(resolvedHref)

            let labelHTML = String(html[labelRange])
            let labelNoTags = self.replacingRegex(pattern: "<[^>]+>", in: labelHTML, with: " ")
            let label = self.normalizeWhitespace(self.decodeHTMLEntities(labelNoTags))
            links.append((href: resolvedHref, text: label))
        }
        return links
    }

    private static func replacingRegex(pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        var decoded = text
        let entities: [(String, String)] = [
            ("&nbsp;", " "),
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
        ]
        for (entity, value) in entities {
            decoded = decoded.replacingOccurrences(of: entity, with: value)
        }
        return decoded
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        let collapsedSpaces = self.replacingRegex(pattern: "[\\t\\u{000B}\\f\\r ]+", in: text, with: " ")
        let collapsedLines = self.replacingRegex(pattern: "\\n{3,}", in: collapsedSpaces, with: "\n\n")
        return collapsedLines.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func handleTelegramSend(
        command: String,
        params: GatewayJSONValue?,
        urlSession: URLSession,
        telegramConfig: GatewayLocalTelegramConfig) async -> ToolResult
    {
        guard telegramConfig.isConfigured else {
            return ToolResult(payload: .null, error: "telegram.send failed: bot token is not configured")
        }
        guard let toolParams = GatewayPayloadCodec.decode(params, as: TelegramSendParams.self) else {
            return ToolResult(payload: .null, error: "invalid telegram.send params")
        }
        let text = toolParams.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return ToolResult(payload: .null, error: "invalid telegram.send params: text required")
        }

        let chatID =
            self.trimmedStringOrNil(toolParams.chatId)
            ?? self.trimmedStringOrNil(toolParams.to)
            ?? self.trimmedStringOrNil(telegramConfig.defaultChatID)
        guard let chatID else {
            return ToolResult(
                payload: .null,
                error: "telegram.send failed: chatId/to missing and no default chat configured")
        }

        guard let endpointURL = URL(string: "https://api.telegram.org/bot\(telegramConfig.botToken)/sendMessage") else {
            return ToolResult(payload: .null, error: "telegram.send failed: malformed bot token")
        }

        var bodyObject: [String: Any] = [
            "chat_id": chatID,
            "text": text,
        ]

        if let parseMode = self.trimmedStringOrNil(toolParams.parseMode) {
            bodyObject["parse_mode"] = parseMode
        }
        if let disablePreview = toolParams.disableWebPagePreview {
            bodyObject["disable_web_page_preview"] = disablePreview
        }
        if let disableNotification = toolParams.disableNotification {
            bodyObject["disable_notification"] = disableNotification
        }

        let payloadData: Data
        do {
            payloadData = try JSONSerialization.data(withJSONObject: bodyObject, options: [])
        } catch {
            return ToolResult(payload: .null, error: "telegram.send failed: invalid request payload")
        }

        do {
            var request = URLRequest(url: endpointURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 20.0
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = payloadData

            let (data, response) = try await urlSession.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            let decoded = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
            let okFlag = (decoded?["ok"] as? Bool) ?? false

            guard statusCode >= 200, statusCode < 300, okFlag else {
                let description =
                    (decoded?["description"] as? String)
                    ?? String(data: data, encoding: .utf8)
                    ?? "unknown Telegram API error"
                return ToolResult(
                    payload: .null,
                    error: "telegram.send failed: status \(statusCode) \(description)")
            }

            let messageID = self.telegramMessageID(from: decoded?["result"])
            var payload: [String: GatewayJSONValue] = [
                "ok": .bool(true),
                "command": .string(command),
                "channel": .string("telegram"),
                "chatId": .string(chatID),
                "messageId": messageID.map { .string($0) } ?? .null,
                "statusCode": .integer(Int64(statusCode)),
            ]
            if let description = decoded?["description"] as? String {
                payload["description"] = .string(description)
            }
            return ToolResult(payload: .object(payload), error: nil)
        } catch {
            return ToolResult(payload: .null, error: "telegram.send failed: \(error.localizedDescription)")
        }
    }

    private static func telegramMessageID(from rawResult: Any?) -> String? {
        guard let resultObject = rawResult as? [String: Any] else {
            return nil
        }
        if let messageID = resultObject["message_id"] as? Int {
            return String(messageID)
        }
        if let messageID = resultObject["message_id"] as? Int64 {
            return String(messageID)
        }
        if let messageID = resultObject["message_id"] as? NSNumber {
            return messageID.stringValue
        }
        if let messageID = resultObject["message_id"] as? String {
            let trimmed = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func trimmedStringOrNil(_ raw: String?) -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func extractHydrationText(
        from source: String,
        maxChars: Int) -> (text: String, signalCount: Int, signalNames: [String])
    {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        var snippets: [String] = []
        var signalNames: [String] = []
        let markerSignals: [(marker: String, name: String)] = [
            ("__NEXT_DATA__", "next"),
            ("window.__NEXT_DATA__", "next"),
            ("window.__INITIAL_STATE__", "initial_state"),
            ("window.__NUXT__", "nuxt"),
            ("window.__APOLLO_STATE__", "apollo"),
            ("window.__PRELOADED_STATE__", "preloaded_state"),
            ("window.__STATE__", "state"),
            ("window.__DATA__", "data"),
        ]

        for signal in markerSignals {
            guard let jsonObject = self.extractAssignedJSONObject(script: normalized, marker: signal.marker) else {
                continue
            }
            let extracted = self.extractJSONValueText(jsonObject)
            if extracted.isEmpty {
                continue
            }
            snippets.append(extracted)
            signalNames.append(signal.name)
        }

        for jsonBody in self.extractJSONScriptBlocks(from: normalized) {
            let extracted = self.extractJSONValueText(jsonBody)
            if extracted.isEmpty {
                continue
            }
            snippets.append(extracted)
            signalNames.append("json-script")
        }

        let merged = self.normalizeWhitespace(snippets.joined(separator: "\n\n"))
        guard !merged.isEmpty else {
            return ("", 0, [])
        }
        let clamped = self.clampText(merged, maxChars: maxChars)
        return (clamped.text, snippets.count, Array(signalNames.prefix(20)))
    }

    private static func extractAssignedJSONObject(script: String, marker: String) -> String? {
        guard let markerRange = script.range(of: marker) else {
            return nil
        }
        let markerTail = script[markerRange.upperBound...]
        guard let equalsIndex = markerTail.firstIndex(of: "=") else {
            return nil
        }
        let assignmentTail = markerTail[markerTail.index(after: equalsIndex)...]
        guard let braceStart = assignmentTail.firstIndex(of: "{") else {
            return nil
        }
        return self.extractBalancedBraces(in: assignmentTail, from: braceStart)
    }

    private static func extractBalancedBraces(in text: Substring, from start: Substring.Index) -> String? {
        var depth = 0
        var inString: Character?
        var escaping = false

        var index = start
        while index < text.endIndex {
            let char = text[index]
            if let quote = inString {
                if escaping {
                    escaping = false
                } else if char == "\\" {
                    escaping = true
                } else if char == quote {
                    inString = nil
                }
                index = text.index(after: index)
                continue
            }

            if char == "\"" || char == "'" {
                inString = char
                index = text.index(after: index)
                continue
            }

            if char == "{" {
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[start...index])
                }
            }

            index = text.index(after: index)
        }
        return nil
    }

    private static func extractJSONScriptBlocks(from html: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<script\b([^>]*)>([\s\S]*?)</script>"#,
            options: [.caseInsensitive])
        else {
            return []
        }
        let matches = regex.matches(
            in: html,
            options: [],
            range: NSRange(location: 0, length: html.utf16.count))
        var blocks: [String] = []
        for match in matches {
            guard match.numberOfRanges >= 3,
                  let attrsRange = Range(match.range(at: 1), in: html),
                  let bodyRange = Range(match.range(at: 2), in: html)
            else {
                continue
            }
            let attrs = html[attrsRange].lowercased()
            guard attrs.contains("application/ld+json") || attrs.contains("application/json") else {
                continue
            }
            let body = String(html[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                blocks.append(body)
            }
        }
        return blocks
    }

    private static func extractJSONValueText(_ jsonLike: String) -> String {
        let data = Data(jsonLike.utf8)
        if let object = try? JSONSerialization.jsonObject(with: data),
           let flattened = self.flattenJSONStrings(from: object),
           !flattened.isEmpty
        {
            return flattened
        }
        return self.extractQuotedStringLiterals(from: jsonLike)
    }

    private static func flattenJSONStrings(from object: Any) -> String? {
        var strings: [String] = []
        self.collectJSONStrings(from: object, into: &strings)
        guard !strings.isEmpty else { return nil }
        return self.normalizeWhitespace(strings.joined(separator: "\n"))
    }

    private static func collectJSONStrings(from value: Any, into output: inout [String]) {
        switch value {
        case let dictionary as [String: Any]:
            for (_, nested) in dictionary {
                self.collectJSONStrings(from: nested, into: &output)
            }
        case let array as [Any]:
            for nested in array {
                self.collectJSONStrings(from: nested, into: &output)
            }
        case let string as String:
            let normalized = self.normalizeWhitespace(string)
            if normalized.count >= 24 {
                output.append(normalized)
            }
        default:
            break
        }
    }

    private static func extractQuotedStringLiterals(from text: String) -> String {
        let patterns = [
            #""((?:[^"\\]|\\.){24,})""#,
            #"'((?:[^'\\]|\\.){24,})'"#,
        ]
        var parts: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                continue
            }
            let matches = regex.matches(
                in: text,
                options: [],
                range: NSRange(location: 0, length: text.utf16.count))
            for match in matches {
                guard match.numberOfRanges >= 2,
                      let captureRange = Range(match.range(at: 1), in: text)
                else {
                    continue
                }
                let raw = String(text[captureRange])
                let unescaped = raw
                    .replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\t", with: "\t")
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\'", with: "'")
                    .replacingOccurrences(of: "\\\\", with: "\\")
                let normalized = self.normalizeWhitespace(unescaped)
                if normalized.count >= 24 {
                    parts.append(normalized)
                }
            }
        }
        return self.normalizeWhitespace(parts.joined(separator: "\n"))
    }

    private static func handleRead(
        command: String,
        params: GatewayJSONValue?,
        workspaceRoot: URL) -> ToolResult
    {
        guard let toolParams = GatewayPayloadCodec.decode(params, as: ReadParams.self) else {
            return ToolResult(payload: .null, error: "invalid read params")
        }
        do {
            let fileURL = try self.resolveWorkspaceFileURL(rawPath: toolParams.path, workspaceRoot: workspaceRoot)
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            let maxChars = max(1, min(toolParams.maxChars ?? 24000, 200_000))
            let truncated = text.count > maxChars
            let body = truncated ? String(text.prefix(maxChars)) : text
            return ToolResult(
                payload: .object([
                    "ok": .bool(true),
                    "command": .string(command),
                    "path": .string(self.relativePath(fileURL: fileURL, workspaceRoot: workspaceRoot)),
                    "text": .string(body),
                    "truncated": .bool(truncated),
                    "chars": .integer(Int64(text.count)),
                ]),
                error: nil)
        } catch {
            return ToolResult(payload: .null, error: "read failed: \(error.localizedDescription)")
        }
    }

    private static func handleLs(
        command: String,
        params: GatewayJSONValue?,
        workspaceRoot: URL) -> ToolResult
    {
        let lsParams = GatewayPayloadCodec.decode(
            params, as: LsParams.self)
        let relativePath = (lsParams?.path ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let targetURL: URL = if relativePath.isEmpty
            || relativePath == "."
        {
            workspaceRoot
        } else {
            workspaceRoot
                .appendingPathComponent(relativePath)
        }

        // Verify inside workspace
        let stdRoot = workspaceRoot.standardizedFileURL.path
        let rootPrefix = stdRoot.hasSuffix("/")
            ? stdRoot : stdRoot + "/"
        let stdTarget = targetURL.standardizedFileURL.path
        guard stdTarget == stdRoot
            || stdTarget.hasPrefix(rootPrefix)
        else {
            return ToolResult(
                payload: .null,
                error: "path escapes workspace root")
        }

        let fm = FileManager.default
        let recursive = lsParams?.recursive ?? false

        var entries: [GatewayJSONValue] = []
        let maxEntries = 500

        if recursive {
            guard let enumerator = fm.enumerator(
                at: targetURL,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isDirectoryKey,
                    .fileSizeKey,
                ],
                options: [.skipsHiddenFiles])
            else {
                return ToolResult(
                    payload: .null,
                    error: "cannot enumerate directory")
            }
            for case let fileURL as URL in enumerator {
                if entries.count >= maxEntries { break }
                let fullPath =
                    fileURL.standardizedFileURL.path
                guard fullPath.hasPrefix(rootPrefix) else {
                    continue
                }
                let rel = String(
                    fullPath.dropFirst(rootPrefix.count))
                let values = try? fileURL.resourceValues(
                    forKeys: [
                        .isDirectoryKey, .fileSizeKey,
                    ])
                let isDir =
                    values?.isDirectory ?? false
                var entry: [String: GatewayJSONValue] = [
                    "name": .string(rel),
                    "type": .string(
                        isDir ? "directory" : "file"),
                ]
                if !isDir,
                   let size = values?.fileSize
                {
                    entry["size"] = .integer(Int64(size))
                }
                entries.append(.object(entry))
            }
        } else {
            guard
                let contents = try? fm
                    .contentsOfDirectory(
                        at: targetURL,
                        includingPropertiesForKeys: [
                            .isDirectoryKey,
                            .fileSizeKey,
                        ],
                        options: .skipsHiddenFiles)
            else {
                return ToolResult(
                    payload: .null,
                    error: "cannot list directory")
            }
            for fileURL in contents
                .sorted(by: {
                    $0.lastPathComponent
                        < $1.lastPathComponent
                })
            {
                if entries.count >= maxEntries { break }
                let values = try? fileURL.resourceValues(
                    forKeys: [
                        .isDirectoryKey, .fileSizeKey,
                    ])
                let isDir =
                    values?.isDirectory ?? false
                var entry: [String: GatewayJSONValue] = [
                    "name": .string(
                        fileURL.lastPathComponent),
                    "type": .string(
                        isDir ? "directory" : "file"),
                ]
                if !isDir,
                   let size = values?.fileSize
                {
                    entry["size"] = .integer(Int64(size))
                }
                entries.append(.object(entry))
            }
        }

        return ToolResult(
            payload: .object([
                "ok": .bool(true),
                "command": .string(command),
                "path": .string(
                    relativePath.isEmpty
                        ? "." : relativePath),
                "entries": .array(entries),
                "count": .integer(Int64(entries.count)),
            ]),
            error: nil)
    }

    /// Detect skill files written to the workspace root and redirect
    /// them to `skills/<name>/SKILL.md` so the app discovers them.
    private static func autoCorrectSkillPath(
        path: String,
        content: String,
        workspaceRoot: URL) -> String
    {
        let trimmed = path.trimmingCharacters(
            in: .whitespacesAndNewlines)

        // Only redirect root-level .md files (no directory separators).
        guard trimmed.hasSuffix(".md"),
              !trimmed.contains("/"),
              !trimmed.contains("\\")
        else { return path }

        // Skip known root files.
        let knownRootFiles: Set<String> = [
            "AGENTS.md", "SOUL.md", "TOOLS.md",
            "IDENTITY.md", "USER.md", "HEARTBEAT.md",
            "BOOTSTRAP.md", "MEMORY.md", "NOTES.md",
            "README.md", "DREAM.md",
        ]
        if knownRootFiles.contains(trimmed) { return path }

        // Heuristic: file content looks like a skill definition.
        let upper = content.uppercased()
        let looksLikeSkill =
            upper.contains("## API") || upper.contains("## ENDPOINT")
            || upper.contains("## SETUP") || upper.contains("## WHEN TO USE")
            || upper.contains("SKILL.MD") || upper.contains("## OVERVIEW")
            || upper.contains("CREDENTIAL") || upper.contains("API KEY")
            || upper.contains("## PARAMETERS")

        guard looksLikeSkill else { return path }

        // Derive skill name: "brave_search.md" → "brave_search"
        let base = String(
            trimmed.dropLast(3))  // strip ".md"
            .lowercased()
            .replacingOccurrences(
                of: "[^a-z0-9_]",
                with: "_",
                options: .regularExpression)

        return "skills/\(base)/SKILL.md"
    }

    private static func handleWrite(
        command: String,
        params: GatewayJSONValue?,
        workspaceRoot: URL) -> ToolResult
    {
        guard let toolParams = GatewayPayloadCodec.decode(params, as: WriteParams.self) else {
            return ToolResult(payload: .null, error: "invalid write params")
        }
        do {
            let correctedPath = self.autoCorrectSkillPath(
                path: toolParams.path,
                content: toolParams.content,
                workspaceRoot: workspaceRoot)
            let wasRedirected = correctedPath != toolParams.path
            let fileURL = try self.resolveWorkspaceFileURL(rawPath: correctedPath, workspaceRoot: workspaceRoot)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try toolParams.content.write(to: fileURL, atomically: true, encoding: .utf8)
            var result: [String: GatewayJSONValue] = [
                "ok": .bool(true),
                "command": .string(command),
                "path": .string(self.relativePath(fileURL: fileURL, workspaceRoot: workspaceRoot)),
                "bytesWritten": .integer(Int64(toolParams.content.utf8.count)),
            ]
            if wasRedirected {
                result["redirectedFrom"] = .string(toolParams.path)
                result["note"] = .string(
                    "Skill file auto-redirected to skills/ directory. "
                        + "Always use skills/<name>/SKILL.md for skill files.")
            }
            return ToolResult(
                payload: .object(result),
                error: nil)
        } catch {
            return ToolResult(payload: .null, error: "write failed: \(error.localizedDescription)")
        }
    }

    private static func handleEdit(
        command: String,
        params: GatewayJSONValue?,
        workspaceRoot: URL) -> ToolResult
    {
        guard let toolParams = GatewayPayloadCodec.decode(params, as: EditParams.self) else {
            return ToolResult(payload: .null, error: "invalid edit params")
        }
        guard !toolParams.oldText.isEmpty else {
            return ToolResult(payload: .null, error: "invalid edit params: oldText required")
        }
        do {
            let fileURL = try self.resolveWorkspaceFileURL(rawPath: toolParams.path, workspaceRoot: workspaceRoot)
            let original = try String(contentsOf: fileURL, encoding: .utf8)
            let updated: String
            let replacedCount: Int
            if toolParams.replaceAll == true {
                replacedCount = original.components(separatedBy: toolParams.oldText).count - 1
                updated = original.replacingOccurrences(of: toolParams.oldText, with: toolParams.newText)
            } else {
                if let range = original.range(of: toolParams.oldText) {
                    replacedCount = 1
                    updated = original.replacingCharacters(in: range, with: toolParams.newText)
                } else {
                    replacedCount = 0
                    updated = original
                }
            }
            guard replacedCount > 0 else {
                return ToolResult(payload: .null, error: "edit failed: oldText not found")
            }
            try updated.write(to: fileURL, atomically: true, encoding: .utf8)
            return ToolResult(
                payload: .object([
                    "ok": .bool(true),
                    "command": .string(command),
                    "path": .string(self.relativePath(fileURL: fileURL, workspaceRoot: workspaceRoot)),
                    "replacedCount": .integer(Int64(replacedCount)),
                ]),
                error: nil)
        } catch {
            return ToolResult(payload: .null, error: "edit failed: \(error.localizedDescription)")
        }
    }

    private static func handleApplyPatch(
        command: String,
        params: GatewayJSONValue?,
        workspaceRoot: URL) -> ToolResult
    {
        guard let toolParams = GatewayPayloadCodec.decode(params, as: ApplyPatchParams.self) else {
            return ToolResult(payload: .null, error: "invalid apply_patch params")
        }
        let patchText = toolParams.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !patchText.isEmpty else {
            return ToolResult(payload: .null, error: "invalid apply_patch params: input required")
        }

        do {
            let hunks = try self.parsePatchText(toolParams.input)
            var added: [String] = []
            var modified: [String] = []
            var deleted: [String] = []

            for hunk in hunks {
                switch hunk {
                case let .add(path, lines):
                    let fileURL = try self.resolveWorkspaceFileURL(rawPath: path, workspaceRoot: workspaceRoot)
                    try FileManager.default.createDirectory(
                        at: fileURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
                    added.append(self.relativePath(fileURL: fileURL, workspaceRoot: workspaceRoot))

                case let .delete(path):
                    let fileURL = try self.resolveWorkspaceFileURL(rawPath: path, workspaceRoot: workspaceRoot)
                    try FileManager.default.removeItem(at: fileURL)
                    deleted.append(self.relativePath(fileURL: fileURL, workspaceRoot: workspaceRoot))

                case let .update(path, chunks):
                    let fileURL = try self.resolveWorkspaceFileURL(rawPath: path, workspaceRoot: workspaceRoot)
                    let original = try String(contentsOf: fileURL, encoding: .utf8)
                    let updated = try self.applyUpdateChunks(chunks, to: original)
                    try updated.write(to: fileURL, atomically: true, encoding: .utf8)
                    modified.append(self.relativePath(fileURL: fileURL, workspaceRoot: workspaceRoot))
                }
            }

            return ToolResult(
                payload: .object([
                    "ok": .bool(true),
                    "command": .string(command),
                    "summary": .object([
                        "added": .array(added.map { .string($0) }),
                        "modified": .array(modified.map { .string($0) }),
                        "deleted": .array(deleted.map { .string($0) }),
                    ]),
                ]),
                error: nil)
        } catch {
            return ToolResult(payload: .null, error: "apply_patch failed: \(error.localizedDescription)")
        }
    }

    private static func resolveWorkspaceFileURL(rawPath: String, workspaceRoot: URL) throws -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "GatewayLocalTooling",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "path is required"])
        }

        let candidate: URL = if trimmed.hasPrefix("/") {
            URL(fileURLWithPath: trimmed)
        } else {
            workspaceRoot.appendingPathComponent(trimmed)
        }

        let standardizedRoot = workspaceRoot.standardizedFileURL.path
        let standardizedCandidate = candidate.standardizedFileURL
        let standardizedFile = standardizedCandidate.path
        let rootPrefix = standardizedRoot.hasSuffix("/") ? standardizedRoot : standardizedRoot + "/"
        guard standardizedFile.hasPrefix(rootPrefix) else {
            throw NSError(
                domain: "GatewayLocalTooling",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "path escapes workspace root"])
        }

        let resolved = try self.resolveCaseVariant(fileURL: standardizedCandidate)
        let resolvedPath = resolved.standardizedFileURL.path
        guard resolvedPath.hasPrefix(rootPrefix) else {
            throw NSError(
                domain: "GatewayLocalTooling",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "resolved path escapes workspace root"])
        }
        return resolved
    }

    /// Prevent duplicate files on case-sensitive filesystems when callers use different casing.
    /// If an exact path exists, keep it. Otherwise, reuse a single case-insensitive match.
    private static func resolveCaseVariant(fileURL: URL) throws -> URL {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: fileURL.path) {
            return fileURL
        }

        let parentURL = fileURL.deletingLastPathComponent()
        var parentIsDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: parentURL.path, isDirectory: &parentIsDirectory),
              parentIsDirectory.boolValue
        else {
            return fileURL
        }

        let siblings = try fileManager.contentsOfDirectory(
            at: parentURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        let targetName = fileURL.lastPathComponent.lowercased()
        let matches = siblings.filter { sibling in
            sibling.lastPathComponent.lowercased() == targetName
        }

        if matches.count > 1 {
            throw NSError(
                domain: "GatewayLocalTooling",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "ambiguous path casing: \(fileURL.lastPathComponent)"])
        }
        if let match = matches.first {
            return match
        }
        return fileURL
    }

    private static func relativePath(fileURL: URL, workspaceRoot: URL) -> String {
        let rootPath = workspaceRoot.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if filePath.hasPrefix(prefix) {
            return String(filePath.dropFirst(prefix.count))
        }
        return fileURL.lastPathComponent
    }

    private static func parsePatchText(_ input: String) throws -> [PatchHunk] {
        let lines = input.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        guard let first = lines.first, first == "*** Begin Patch" else {
            throw NSError(
                domain: "GatewayLocalTooling",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "missing *** Begin Patch"])
        }

        var index = 1
        var hunks: [PatchHunk] = []
        while index < lines.count {
            let line = lines[index]
            if line == "*** End Patch" {
                return hunks
            }

            if line.hasPrefix("*** Add File: ") {
                let path = String(line.dropFirst("*** Add File: ".count)).trimmingCharacters(in: .whitespaces)
                index += 1
                var content: [String] = []
                while index < lines.count, !lines[index].hasPrefix("*** ") {
                    let current = lines[index]
                    guard current.hasPrefix("+") else {
                        throw NSError(
                            domain: "GatewayLocalTooling",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "add file lines must start with +"])
                    }
                    content.append(String(current.dropFirst()))
                    index += 1
                }
                hunks.append(.add(path: path, lines: content))
                continue
            }

            if line.hasPrefix("*** Delete File: ") {
                let path = String(line.dropFirst("*** Delete File: ".count)).trimmingCharacters(in: .whitespaces)
                hunks.append(.delete(path: path))
                index += 1
                continue
            }

            if line.hasPrefix("*** Update File: ") {
                let path = String(line.dropFirst("*** Update File: ".count)).trimmingCharacters(in: .whitespaces)
                index += 1
                var chunks: [PatchChunk] = []
                var oldLines: [String] = []
                var newLines: [String] = []

                func flushChunk() {
                    if !oldLines.isEmpty || !newLines.isEmpty {
                        chunks.append(PatchChunk(oldLines: oldLines, newLines: newLines))
                        oldLines.removeAll(keepingCapacity: true)
                        newLines.removeAll(keepingCapacity: true)
                    }
                }

                while index < lines.count, !lines[index].hasPrefix("*** ") {
                    let current = lines[index]
                    if current.hasPrefix("@@") {
                        flushChunk()
                        index += 1
                        continue
                    }
                    if current == "*** End of File" {
                        index += 1
                        continue
                    }
                    guard let prefix = current.first else {
                        index += 1
                        continue
                    }
                    let body = String(current.dropFirst())
                    switch prefix {
                    case " ":
                        oldLines.append(body)
                        newLines.append(body)
                    case "-":
                        oldLines.append(body)
                    case "+":
                        newLines.append(body)
                    default:
                        throw NSError(
                            domain: "GatewayLocalTooling",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "invalid update line prefix: \(prefix)"])
                    }
                    index += 1
                }
                flushChunk()
                hunks.append(.update(path: path, chunks: chunks))
                continue
            }

            throw NSError(
                domain: "GatewayLocalTooling",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "unexpected patch line: \(line)"])
        }

        throw NSError(
            domain: "GatewayLocalTooling",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "missing *** End Patch"])
    }

    private static func applyUpdateChunks(_ chunks: [PatchChunk], to content: String) throws -> String {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let hadTrailingNewline = normalized.hasSuffix("\n")
        var lines = normalized.components(separatedBy: "\n")
        if hadTrailingNewline, !lines.isEmpty {
            lines.removeLast()
        }
        if lines.count == 1, lines[0].isEmpty, normalized.isEmpty {
            lines.removeAll()
        }

        var searchStart = 0
        for chunk in chunks {
            guard let matchIndex = self.findSubsequenceIndex(
                in: lines,
                subsequence: chunk.oldLines,
                startAt: searchStart)
            else {
                throw NSError(
                    domain: "GatewayLocalTooling",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "patch chunk context not found"])
            }

            let end = matchIndex + chunk.oldLines.count
            lines.replaceSubrange(matchIndex..<end, with: chunk.newLines)
            searchStart = matchIndex + chunk.newLines.count
        }

        var output = lines.joined(separator: "\n")
        if hadTrailingNewline {
            output += "\n"
        }
        return output
    }

    private static func findSubsequenceIndex(
        in source: [String],
        subsequence: [String],
        startAt: Int) -> Int?
    {
        if subsequence.isEmpty {
            return min(max(0, startAt), source.count)
        }
        if source.count < subsequence.count {
            return nil
        }

        let start = max(0, startAt)
        let maxIndex = source.count - subsequence.count
        if start > maxIndex {
            return nil
        }
        for index in start...maxIndex {
            let slice = source[index..<(index + subsequence.count)]
            if Array(slice) == subsequence {
                return index
            }
        }
        return nil
    }
}
