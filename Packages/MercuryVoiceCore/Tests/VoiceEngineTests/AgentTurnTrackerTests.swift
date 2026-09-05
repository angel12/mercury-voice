import Foundation
import Testing

@testable import HermesKit
@testable import VoiceEngine

@Suite("AgentTurnTracker")
struct AgentTurnTrackerTests {
    private func makeTracker() -> AgentTurnTracker {
        AgentTurnTracker(submit: { _, _ in }, interrupt: {})
    }

    private func event(_ type: String, _ payloadJSON: String) -> GatewayEvent {
        let payload = try! JSONDecoder().decode(JSONValue.self, from: Data(payloadJSON.utf8))
        return GatewayEvent(type: type, sessionID: "s", payload: payload)
    }

    @Test func deltasAccumulateIntoOneBubble() async {
        let tracker = makeTracker()
        await tracker.handle(event: event("message.start", "{}"))
        #expect(await tracker.isBusy)
        await tracker.handle(event: event("message.delta", #"{"text": "Hel"}"#))
        await tracker.handle(event: event("message.delta", #"{"text": "lo"}"#))

        let pending = await tracker.pendingSpeech()
        #expect(pending?.text == "Hello")
        #expect(pending?.pending == true)
    }

    @Test func completeSealsAndClearsBusy() async {
        let tracker = makeTracker()
        await tracker.handle(event: event("message.delta", #"{"text": "Hi"}"#))
        await tracker.handle(
            event: event("message.complete", #"{"text": "Hi there", "status": "complete"}"#))

        #expect(await !tracker.isBusy)
        let pending = await tracker.pendingSpeech()
        // complete text prefix-extends the streamed text, so it's adopted.
        #expect(pending?.text == "Hi there")
        #expect(pending?.pending == false)
    }

    @Test func divergentCompleteKeepsStreamedText() async {
        let tracker = makeTracker()
        await tracker.handle(event: event("message.delta", #"{"text": "Hello world"}"#))
        await tracker.handle(
            event: event("message.complete", #"{"text": "Different", "status": "complete"}"#))
        // Append-only invariant: never shrink/diverge the spoken source.
        #expect(await tracker.pendingSpeech()?.text == "Hello world")
    }

    @Test func interimAlreadyStreamedSealsWithoutDuplication() async {
        let tracker = makeTracker()
        await tracker.handle(event: event("message.delta", #"{"text": "Checking the file."}"#))
        await tracker.handle(
            event: event(
                "message.interim",
                #"{"text": "Checking the file.", "already_streamed": true}"#))
        await tracker.handle(event: event("message.delta", #"{"text": "All good."}"#))
        await tracker.handle(
            event: event("message.complete", #"{"text": "All good.", "status": "complete"}"#))

        let pending = await tracker.pendingSpeech()
        #expect(pending?.text == "Checking the file.\n\nAll good.")
        #expect(pending?.pending == false)
    }

    @Test func interimNotStreamedAppendsBubble() async {
        let tracker = makeTracker()
        await tracker.handle(
            event: event(
                "message.interim", #"{"text": "Let me look.", "already_streamed": false}"#))
        #expect(await tracker.pendingSpeech()?.text == "Let me look.")
    }

    @Test func watermarkPreventsDoubleSpeaking() async {
        let tracker = makeTracker()
        await tracker.handle(event: event("message.delta", #"{"text": "First reply"}"#))
        await tracker.handle(event: event("message.complete", #"{"text": "First reply"}"#))
        await tracker.consumePendingSpeech()
        #expect(await tracker.pendingSpeech() == nil)

        await tracker.handle(event: event("message.delta", #"{"text": "Second"}"#))
        let pending = await tracker.pendingSpeech()
        #expect(pending?.text == "Second")
        // The id moved past the consumed bubble.
        #expect(pending?.id == "1")
    }

    @Test func toolOnlyTurnHasNothingToSpeak() async {
        let tracker = makeTracker()
        await tracker.handle(event: event("message.start", "{}"))
        await tracker.handle(event: event("message.complete", #"{"text": ""}"#))
        #expect(await tracker.pendingSpeech() == nil)
        #expect(await !tracker.isBusy)
    }

    @Test func errorEventUnwedgesBusy() async {
        let tracker = makeTracker()
        await tracker.handle(event: event("message.start", "{}"))
        #expect(await tracker.isBusy)
        await tracker.handle(event: event("error", #"{"message": "boom"}"#))
        #expect(await !tracker.isBusy)
    }

    @Test func errorSealsPartialReplyAndSeparatesTheNextTurn() async {
        let tracker = makeTracker()
        await tracker.handle(event: event("message.delta", #"{"text": "Partial reply"}"#))
        await tracker.handle(event: event("error", #"{"message": "boom"}"#))
        #expect(await tracker.pendingSpeech()?.pending == false)
        await tracker.consumePendingSpeech()

        await tracker.handle(event: event("message.start", "{}"))
        await tracker.handle(event: event("message.delta", #"{"text": "Next reply"}"#))
        #expect(await tracker.pendingSpeech()?.text == "Next reply")
        #expect(await tracker.visibleAssistantText == "Partial reply\n\nNext reply")
    }
}
