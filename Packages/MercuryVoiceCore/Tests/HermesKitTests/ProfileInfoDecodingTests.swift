import Foundation
import Testing

@testable import HermesKit

/// Fixtures shaped like one entry of `profiles.list` in
/// tui_gateway/methods_profiles.py.
@Suite("Profile info decoding")
struct ProfileInfoDecodingTests {
    private func json(_ string: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))
    }

    @Test func usesDisplayNameWhenProvided() throws {
        let profile = ProfileInfo(
            json: try json(#"{"name": "default", "display_name": "Demo", "is_default": true}"#))
        #expect(profile?.name == "default")
        #expect(profile?.displayName == "Demo")
        #expect(profile?.isDefault == true)
    }

    @Test func fallsBackToIdWhenDisplayNameMissingOrBlank() throws {
        let missing = ProfileInfo(json: try json(#"{"name": "work"}"#))
        #expect(missing?.displayName == "work")

        let blank = ProfileInfo(json: try json(#"{"name": "work", "display_name": "  "}"#))
        #expect(blank?.displayName == "work")
    }
}
