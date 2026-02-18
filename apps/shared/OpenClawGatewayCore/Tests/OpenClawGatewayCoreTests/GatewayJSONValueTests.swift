import Foundation
import XCTest
@testable import OpenClawGatewayCore

final class GatewayJSONValueTests: XCTestCase {
    func testFoundationJSONObjectValueIsJSONSerializable() throws {
        let value: GatewayJSONValue = .object([
            "type": .string("object"),
            "enabled": .bool(true),
            "count": .integer(3),
            "ratio": .double(0.5),
            "list": .array([
                .string("a"),
                .null,
                .object([
                    "nested": .bool(false),
                ]),
            ]),
        ])

        guard let object = value.foundationJSONObjectValue else {
            XCTFail("Expected foundation object")
            return
        }

        XCTAssertTrue(JSONSerialization.isValidJSONObject(object))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: object))
    }

    func testFoundationJSONObjectValueReturnsNilForScalar() {
        let value: GatewayJSONValue = .string("scalar")
        XCTAssertNil(value.foundationJSONObjectValue)
    }
}
