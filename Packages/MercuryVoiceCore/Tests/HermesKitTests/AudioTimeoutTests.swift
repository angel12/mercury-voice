import Foundation
import Testing

@testable import HermesKit

/// Issue #144 item 5: the relay audio endpoints scale their timeout with the
/// payload, matching upstream's desktop client
/// (`apps/desktop/src/api/system.ts`, 2bb531b67a): a 180 s floor, a 600 s
/// cap, and 0.1 ms per data-URL char (transcribe) / 35 ms per text char
/// (speak) in between. A fixed 120 s cut off long recordings and cold local
/// Whisper loads while the backend was still working.
@Suite("Audio request timeouts")
struct AudioTimeoutTests {
    @Test func transcribeShortClipGetsTheFloor() {
        #expect(HermesRESTClient.transcribeTimeout(dataURLLength: 0) == 180)
        #expect(HermesRESTClient.transcribeTimeout(dataURLLength: 50_000) == 180)
    }

    @Test func transcribeScalesWithDataURLLength() {
        // 2.5M chars × 0.1 ms = 250 s.
        #expect(HermesRESTClient.transcribeTimeout(dataURLLength: 2_500_000) == 250)
    }

    @Test func transcribeClampsToTheCap() {
        #expect(HermesRESTClient.transcribeTimeout(dataURLLength: 6_000_000) == 600)
        #expect(HermesRESTClient.transcribeTimeout(dataURLLength: 50_000_000) == 600)
    }

    @Test func speakShortTextGetsTheFloor() {
        #expect(HermesRESTClient.speakTimeout(textLength: 0) == 180)
        #expect(HermesRESTClient.speakTimeout(textLength: 5_000) == 180)
    }

    @Test func speakScalesWithTextLength() {
        // 10k chars × 35 ms = 350 s.
        #expect(HermesRESTClient.speakTimeout(textLength: 10_000) == 350)
    }

    @Test func speakClampsToTheCap() {
        #expect(HermesRESTClient.speakTimeout(textLength: 20_000) == 600)
    }
}
