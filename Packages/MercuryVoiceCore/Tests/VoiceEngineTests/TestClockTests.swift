import Foundation
import Testing

@Suite("Test clock cancellation")
struct TestClockTests {
    @Test func alreadyCancelledSleepDoesNotRegisterASleeper() async {
        let clock = TestClock()
        let gate = GatedTranscriber()
        gate.armGate()
        let outcome = NoticeBox()
        let task = Task {
            _ = try? await gate.transcribe(makeUtterance())
            do {
                try await clock.sleep(for: .seconds(60))
                outcome.append("completed")
            } catch is CancellationError {
                outcome.append("cancelled")
            } catch {
                outcome.append("unexpected error")
            }
        }
        task.cancel()
        gate.release()
        let cancelled = await eventually { outcome.list == ["cancelled"] }
        #expect(cancelled)
        #expect(clock.sleeperCount == 0)
        // Release a broken implementation too, so a failed test cannot hang.
        clock.advance(by: .seconds(60))
        await task.value
    }
}
