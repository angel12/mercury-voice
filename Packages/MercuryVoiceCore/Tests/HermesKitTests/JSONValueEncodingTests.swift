import Foundation
import Testing

@testable import HermesKit

@Suite("JSON numeric encoding")
struct JSONValueEncodingTests {
    @Test(arguments: [
        Double(Int64.max), Double(Int64.max).nextDown, Double(Int64.max).nextUp,
        Double(Int64.min), Double(Int64.min).nextDown, 0, 42, -42, 1.5,
    ])
    func finiteNumbersRoundTripWithoutTrapping(value: Double) throws {
        let data = try JSONEncoder().encode(JSONValue.number(value))
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded.doubleValue == value)
    }

    @Test(arguments: [Double.infinity, -Double.infinity, Double.nan])
    func nonfiniteNumbersThrowInsteadOfTrapping(value: Double) {
        #expect(throws: EncodingError.self) {
            try JSONEncoder().encode(JSONValue.number(value))
        }
    }
}
