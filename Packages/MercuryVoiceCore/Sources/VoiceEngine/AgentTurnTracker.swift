import Foundation
import HermesKit

/// Tracks the agent turn from gateway events and answers the engine's
/// questions: is the turn busy, and what reply text hasn't been spoken yet.
///
/// The wire has no message ids — `message.delta {text}` accumulates,
/// `message.interim {text, already_streamed}` seals the current segment, and
/// `message.complete {text, status}` replaces the streaming buffer — so
/// bubbles are synthesized locally with monotonically increasing ids. The
/// spoken watermark (`lastSpokenBubbleID`) is what makes multi-bubble turns
/// speak exactly once.
public actor AgentTurnTracker: AgentInterfacing {
    private struct Bubble {
        var id: Int
        var text: String
        var pending: Bool
        /// Caption override for a `response_transformed` rewrite that does
        /// not extend `text` — shown, never spoken.
        var displayText: String?
    }

    private var bubbles: [Bubble] = []
    private var nextBubbleID = 0
    private var lastSpokenBubbleID = -1
    private var busy = false

    private let submitAction: @Sendable (String, Bool) async throws -> Void
    private let interruptAction: @Sendable () async -> Void
    private var onChange: (@Sendable () -> Void)?

    public init(
        submit: @escaping @Sendable (String, Bool) async throws -> Void,
        interrupt: @escaping @Sendable () async -> Void
    ) {
        self.submitAction = submit
        self.interruptAction = interrupt
    }

    public func setOnChange(_ handler: (@Sendable () -> Void)?) {
        onChange = handler
    }

    // MARK: AgentInterfacing

    public var isBusy: Bool { busy }

    public func pendingSpeech() -> PendingSpeech? {
        let unspoken = bubbles.filter { $0.id > lastSpokenBubbleID }
        guard let first = unspoken.first, let last = unspoken.last else { return nil }
        return PendingSpeech(
            id: String(first.id),
            text: unspoken.map(\.text).joined(separator: "\n\n"),
            pending: last.pending)
    }

    public func consumePendingSpeech() {
        if let last = bubbles.last { lastSpokenBubbleID = last.id }
    }

    public func submit(text: String, interrupted: Bool) async throws {
        busy = true
        notifyChange()
        do {
            try await submitAction(text, interrupted)
        } catch {
            busy = false
            notifyChange()
            throw error
        }
    }

    public func interrupt() async {
        await interruptAction()
    }

    // MARK: Event ingestion

    /// Feed gateway events for the conversation's session here.
    public func handle(event: GatewayEvent) {
        switch event.type {
        case GatewayEvent.Kind.messageStart:
            // Text a previous turn left open (its complete never arrived)
            // must not run into this turn's reply (hermes-agent 7c0b206cc9).
            sealOpenBubble(finalText: nil)
            busy = true

        case GatewayEvent.Kind.messageDelta:
            busy = true
            appendDelta(event.payload["text"]?.stringValue ?? "")

        case GatewayEvent.Kind.messageInterim:
            let text = event.payload["text"]?.stringValue ?? ""
            let alreadyStreamed = event.payload["already_streamed"]?.truthy ?? false
            if alreadyStreamed {
                // The text already arrived via deltas — just seal the open
                // bubble; appending the payload would speak it twice.
                sealOpenBubble(finalText: text)
            } else if let open = openBubbleText, !open.isEmpty, text.hasPrefix(open) {
                // Exact-match semantics since hermes-agent 167f0ef5fa: false
                // also means only a cut-off prefix streamed, and the payload
                // is the whole segment — complete it rather than repeat it.
                sealOpenBubble(finalText: text)
            } else {
                sealOpenBubble(finalText: nil)
                if !text.isEmpty {
                    bubbles.append(Bubble(id: takeBubbleID(), text: text, pending: false))
                }
            }

        case GatewayEvent.Kind.messageComplete:
            let text = event.payload["text"]?.stringValue ?? ""
            let transformed = event.payload["response_transformed"]?.truthy ?? false
            if hasOpenBubble {
                sealOpenBubble(finalText: text, captionOverride: transformed)
            } else if !text.isEmpty {
                bubbles.append(Bubble(id: takeBubbleID(), text: text, pending: false))
            }
            busy = false

        case GatewayEvent.Kind.error:
            // Defensive unwedge: a dead turn must not leave the loop stuck
            // in thinking forever. Seal partial text too, so speech can
            // finish and the next turn cannot extend a consumed bubble.
            sealOpenBubble(finalText: nil)
            busy = false

        default:
            return
        }
        notifyChange()
    }

    /// Reset for a new/reattached session. `busy` seeds from the resume
    /// payload's `running` flag when a turn was in flight at reconnect.
    public func reset(busy: Bool = false) {
        bubbles.removeAll()
        lastSpokenBubbleID = -1
        self.busy = busy
        notifyChange()
    }

    /// Everything the assistant has said this session view — for captions.
    public var visibleAssistantText: String {
        bubbles.map { $0.displayText ?? $0.text }.joined(separator: "\n\n")
    }

    // MARK: Bubbles

    private var hasOpenBubble: Bool { bubbles.last?.pending == true }

    private var openBubbleText: String? { hasOpenBubble ? bubbles.last?.text : nil }

    private func takeBubbleID() -> Int {
        defer { nextBubbleID += 1 }
        return nextBubbleID
    }

    private func appendDelta(_ text: String) {
        guard !text.isEmpty else { return }
        if hasOpenBubble, let index = bubbles.indices.last {
            bubbles[index].text += text
        } else {
            bubbles.append(Bubble(id: takeBubbleID(), text: text, pending: true))
        }
    }

    /// Close the streaming bubble. The authoritative final text is used only
    /// when it append-extends what was streamed — the engine's spoken-length
    /// diffing requires the joined text to be strictly append-only, so a
    /// rewrite that shortens or diverges keeps the streamed text instead.
    /// `captionOverride` (`message.complete.response_transformed`, whose text
    /// the server marks authoritative) still shows such a rewrite on screen.
    private func sealOpenBubble(finalText: String?, captionOverride: Bool = false) {
        guard hasOpenBubble, let index = bubbles.indices.last else { return }
        if let finalText, finalText.hasPrefix(bubbles[index].text) {
            bubbles[index].text = finalText
        } else if let finalText, captionOverride {
            bubbles[index].displayText = finalText
        }
        bubbles[index].pending = false
    }

    private func notifyChange() {
        onChange?()
    }
}
