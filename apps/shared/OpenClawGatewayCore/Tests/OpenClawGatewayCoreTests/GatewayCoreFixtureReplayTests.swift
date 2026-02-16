import Foundation
import XCTest
@testable import OpenClawGatewayCore

private struct FixtureReplayEntry: Decodable {
    struct Request: Decodable {
        let method: String
    }

    struct Outcome: Decodable {
        struct ErrorPayload: Decodable {
            let message: String
        }

        let ok: Bool
        let error: ErrorPayload?
    }

    let name: String
    let request: Request
    let outcome: Outcome
}

final class GatewayCoreFixtureReplayTests: XCTestCase {
    func testGatewayCoreReplaysContractFixtures() throws {
        let fixtureDir = try Self.locateFixtureDirectory()
        let fixturePaths = try FileManager.default.contentsOfDirectory(
            at: fixtureDir,
            includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "index.json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        XCTAssertFalse(fixturePaths.isEmpty, "Expected gateway core fixture files")

        let decoder = JSONDecoder()
        let core = GatewayCore(startedAtMs: 1_700_000_000_000)

        for path in fixturePaths {
            let data = try Data(contentsOf: path)
            let fixture = try decoder.decode(FixtureReplayEntry.self, from: data)

            if fixture.name.contains("unauthorized") {
                // Auth handshake behavior belongs to transport/session layers, not GatewayCore methods.
                continue
            }

            let result = core.handle(
                GatewayInvocationRequest(method: fixture.request.method),
                nowMs: 1_700_000_000_500)

            if fixture.outcome.ok {
                if fixture.request.method == "health" {
                    guard case let .success(.health(payload)) = result else {
                        XCTFail("Expected health success for fixture \(fixture.name)")
                        continue
                    }
                    XCTAssertTrue(payload.ok, "Expected health.ok=true for fixture \(fixture.name)")
                } else if fixture.request.method == "status" {
                    guard case let .success(.status(payload)) = result else {
                        XCTFail("Expected status success for fixture \(fixture.name)")
                        continue
                    }
                    XCTAssertEqual(payload.heartbeatDefaultAgentId, "main")
                } else {
                    guard case .success = result else {
                        XCTFail("Expected success for fixture \(fixture.name)")
                        continue
                    }
                }
                continue
            }

            guard case let .failure(error) = result else {
                XCTFail("Expected failure for fixture \(fixture.name)")
                continue
            }
            if let expected = fixture.outcome.error?.message {
                XCTAssertEqual(error.message, expected, "Failure mismatch for fixture \(fixture.name)")
            }
        }
    }

    private static func locateFixtureDirectory() throws -> URL {
        var current = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = current
                .appendingPathComponent("test")
                .appendingPathComponent("fixtures")
                .appendingPathComponent("gateway-core-contract")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            current.deleteLastPathComponent()
        }
        throw NSError(
            domain: "GatewayCoreFixtureReplayTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate test/fixtures/gateway-core-contract"])
    }
}
