import XCTest
@testable import OpenClawGatewayCore

final class GatewayLocalLLMTests: XCTestCase {
    func testNormalizeModelNameCanonicalizesKnownMiniMaxAliases() {
        XCTAssertEqual(
            GatewayOpenAICompatibleLLMProvider.normalizedModelName("MinMax-M2.5", for: .minimaxCompatible),
            "MiniMax-M2.5")
        XCTAssertEqual(
            GatewayOpenAICompatibleLLMProvider.normalizedModelName("minimax/minimax-m2.5", for: .minimaxCompatible),
            "MiniMax-M2.5")
        XCTAssertEqual(
            GatewayOpenAICompatibleLLMProvider.normalizedModelName(" minmax-m2.5-lightning ", for: .minimaxCompatible),
            "MiniMax-M2.5-Lightning")
    }

    func testNormalizeModelNameLeavesUnknownMiniMaxModelUntouched() {
        XCTAssertEqual(
            GatewayOpenAICompatibleLLMProvider.normalizedModelName("custom-model", for: .minimaxCompatible),
            "custom-model")
    }

    func testNormalizeModelNameLeavesOtherProvidersUntouched() {
        XCTAssertEqual(
            GatewayOpenAICompatibleLLMProvider.normalizedModelName(" MinMax-M2.5 ", for: .openAICompatible),
            "MinMax-M2.5")
    }

    func testNormalizeModelNameLeavesGrokModelUntouched() {
        XCTAssertEqual(
            GatewayOpenAICompatibleLLMProvider.normalizedModelName(" grok-3-mini-beta ", for: .grokCompatible),
            "grok-3-mini-beta")
    }

    func testNormalizeOpenAIToolParametersAddsTypeAndPropertiesWhenMissing() {
        let normalized = GatewayOpenAICompatibleLLMProvider.normalizeOpenAIToolParameters(nil)
        XCTAssertEqual(normalized["type"] as? String, "object")
        XCTAssertEqual((normalized["properties"] as? [String: Any])?.count, 0)
    }

    func testNormalizeOpenAIToolParametersAddsPropertiesForObjectType() {
        let normalized = GatewayOpenAICompatibleLLMProvider.normalizeOpenAIToolParameters([
            "type": "object",
            "required": ["query"],
        ])
        XCTAssertEqual(normalized["type"] as? String, "object")
        XCTAssertEqual((normalized["required"] as? [String]) ?? [], ["query"])
        XCTAssertEqual((normalized["properties"] as? [String: Any])?.count, 0)
    }

    func testNormalizeOpenAIToolParametersPreservesExistingProperties() {
        let normalized = GatewayOpenAICompatibleLLMProvider.normalizeOpenAIToolParameters([
            "type": "object",
            "properties": [
                "q": [
                    "type": "string",
                ],
            ],
        ])
        let properties = normalized["properties"] as? [String: [String: String]]
        XCTAssertEqual(properties?["q"]?["type"], "string")
    }

    func testOpenAICompatibleToolNameSanitizesUnsupportedCharacters() {
        XCTAssertEqual(
            GatewayOpenAICompatibleLLMProvider.openAICompatibleToolName("web.render"),
            "web_render")
        XCTAssertEqual(
            GatewayOpenAICompatibleLLMProvider.openAICompatibleToolName(" tools/network.fetch "),
            "tools_network_fetch")
        XCTAssertEqual(
            GatewayOpenAICompatibleLLMProvider.openAICompatibleToolName("..."),
            "tool")
    }

    func testMakeOpenAIToolNameMapProducesUniqueRegexSafeNames() {
        let map = GatewayOpenAICompatibleLLMProvider.makeOpenAIToolNameMap(
            toolNames: [
                "web.render",
                "web_render",
                "web render",
                "web-render",
                "network.fetch",
            ])
        let values = Array(map.values)
        XCTAssertEqual(Set(values).count, values.count)
        XCTAssertEqual(map["web.render"], "web_render")
        XCTAssertEqual(map["network.fetch"], "network_fetch")

        for value in values {
            XCTAssertTrue(value.count <= 64, "tool alias exceeds OpenAI limit: \(value)")
            XCTAssertNotNil(
                value.range(of: #"^[a-zA-Z0-9_-]+$"#, options: .regularExpression),
                "tool alias does not match OpenAI regex: \(value)")
        }
    }

    func testAnthropicToolCallParsingRestoresMappedNames() {
        let calls = GatewayAnthropicCompatibleLLMProvider.decodeToolCallsFromAnthropicContent(
            [
                [
                    "type": "text",
                    "text": "Planning...",
                ],
                [
                    "type": "tool_use",
                    "id": "toolu_01ABC",
                    "name": "web_render",
                    "input": [
                        "url": "https://techcrunch.com",
                        "maxChars": 4000,
                    ],
                ],
            ],
            restoreNamesUsing: [
                "web_render": "web.render",
            ])
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.id, "toolu_01ABC")
        XCTAssertEqual(calls.first?.name, "web.render")
        let argsData = calls.first?.argumentsJSON.data(using: .utf8)
        let args = try? argsData.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertEqual(args?["url"] as? String, "https://techcrunch.com")
        XCTAssertEqual(args?["maxChars"] as? Int, 4000)
    }

    func testAnthropicToolCallParsingFallsBackToEmptyArgumentsOnInvalidInput() {
        let calls = GatewayAnthropicCompatibleLLMProvider.decodeToolCallsFromAnthropicContent(
            [
                [
                    "type": "tool_use",
                    "id": "",
                    "name": "network_fetch",
                    "input": "invalid",
                ],
            ])
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "network_fetch")
        XCTAssertEqual(calls.first?.argumentsJSON, "{}")
        XCTAssertFalse((calls.first?.id ?? "").isEmpty)
    }

    func testEffectiveRequestTimeoutUsesDefaultWhenUnset() {
        let config = GatewayLocalLLMConfig(
            provider: .openAICompatible,
            baseURL: URL(string: "http://localhost:1234"),
            model: "test-model")
        XCTAssertEqual(config.effectiveRequestTimeoutSeconds, 1_200)
    }

    func testEffectiveRequestTimeoutClampsLowAndHighValues() {
        let low = GatewayLocalLLMConfig(
            provider: .openAICompatible,
            baseURL: URL(string: "http://localhost:1234"),
            model: "test-model",
            requestTimeoutSeconds: 2)
        XCTAssertEqual(low.effectiveRequestTimeoutSeconds, 10)

        let high = GatewayLocalLLMConfig(
            provider: .openAICompatible,
            baseURL: URL(string: "http://localhost:1234"),
            model: "test-model",
            requestTimeoutSeconds: 99_999)
        XCTAssertEqual(high.effectiveRequestTimeoutSeconds, 7_200)
    }

    func testEffectiveRequestTimeoutFallsBackForInvalidNumbers() {
        let config = GatewayLocalLLMConfig(
            provider: .openAICompatible,
            baseURL: URL(string: "http://localhost:1234"),
            model: "test-model",
            requestTimeoutSeconds: .nan)
        XCTAssertEqual(config.effectiveRequestTimeoutSeconds, 1_200)
    }
}
