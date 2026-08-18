import Foundation
import Testing

@testable import HermesKit

/// Fixtures shaped like `_get_usage` in tui_gateway/server.py — the dict
/// carried by `session.usage` ticks and `message.complete.usage`.
@Suite("Session usage decoding")
struct SessionUsageDecodingTests {
    private func json(_ string: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))
    }

    @Test func decodesFullUsageDict() throws {
        let usage = SessionUsage(
            json: try json(
                """
                {"model": "hermes-4-405b", "input": 61000, "output": 4200,
                 "reasoning": 900, "prompt": 61000, "completion": 4200,
                 "total": 66100, "calls": 14,
                 "context_used": 61234, "context_max": 128000,
                 "context_percent": 48, "compressions": 1,
                 "active_subagents": 2}
                """))

        #expect(usage?.model == "hermes-4-405b")
        #expect(usage?.totalTokens == 66100)
        #expect(usage?.apiCalls == 14)
        #expect(usage?.contextUsed == 61234)
        #expect(usage?.contextMax == 128000)
        #expect(usage?.contextPercent == 48)
        #expect(usage?.activeSubagents == 2)
    }

    @Test func gaugeFieldsAbsentMeansUnknown() throws {
        // An engine that doesn't track per-window occupancy sends counters
        // only — context* must stay nil so no gauge is rendered.
        let usage = SessionUsage(
            json: try json(#"{"model": "m", "total": 5, "calls": 1}"#))
        #expect(usage != nil)
        #expect(usage?.contextPercent == nil)
        #expect(usage?.contextUsed == nil)
        #expect(usage?.contextMax == nil)
    }

    @Test func rejectsNonObjectPayloads() throws {
        #expect(SessionUsage(json: .string("nope")) == nil)
        #expect(SessionUsage(json: .null) == nil)
        #expect(SessionUsage(json: .array([])) == nil)
    }
}
