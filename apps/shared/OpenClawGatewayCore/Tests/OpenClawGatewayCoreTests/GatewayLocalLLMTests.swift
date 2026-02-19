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
}
