import Foundation
import HermesKit
import VoiceEngine

@testable import MercuryVoice

// Controllable stand-ins for the `ConversationController` seams (issue #75).
// These exist so a test can drive the *real* `openSession` and
// `connectionBecameReady` — including the exact interleaving of the resume
// snapshot, the replay batch, the post-batch prompt read and the live socket
// — without a gateway.

/// Scripted `session.*` RPCs. Answers come from queues in call order, so a
/// test spells out the snapshot the first resume returns, the batch the
/// reconnect replays, and the (later, different) prompt state the post-batch
/// read reports.
final class ScriptedSessionService: SessionServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var resumeAnswers: [JSONValue] = []
    private var createAnswers: [JSONValue] = []
    private var batches: [Result<EventReplayBatch, any Error>] = []
    private var activations: [Result<JSONValue, any Error>] = []
    private var _epoch: String?
    private var _epochOnActivate: String??
    private var _resumedIDs: [String] = []
    private var _eventsSinceCalls: [(sessionID: String, lastSeen: Int)] = []
    private var _activatedIDs: [String] = []
    private var _closedIDs: [String] = []

    /// When set, `resumeSession` suspends here until the test releases it.
    var resumeGate: CallGate?
    /// When set, `eventsSince` suspends here until the test releases it.
    var eventsSinceGate: CallGate?
    /// When set, `activateSession` suspends here until the test releases it —
    /// this is the window a live frame has to arrive in *before* the prompt
    /// read is taken.
    var activateGate: CallGate?
    /// When set, `activateSession` suspends here *after* reading its answer:
    /// the window a live frame has to arrive in *after* the prompt read.
    var activateReturnGate: CallGate?

    init(epoch: String? = "epoch-1") { _epoch = epoch }

    // MARK: Scripting

    func enqueueResume(_ result: JSONValue) { lock.withLock { resumeAnswers.append(result) } }
    func enqueueCreate(_ result: JSONValue) { lock.withLock { createAnswers.append(result) } }
    func enqueueBatch(_ batch: EventReplayBatch) {
        lock.withLock { batches.append(.success(batch)) }
    }
    /// Script `session.events.since` failing — the "no replay contract"
    /// backend, which must fall back to the tracker reset.
    func enqueueBatchFailure(_ error: any Error = HermesError.notConnected) {
        lock.withLock { batches.append(.failure(error)) }
    }
    func enqueueActivation(_ result: JSONValue) {
        lock.withLock { activations.append(.success(result)) }
    }
    /// Script `session.activate` failing — a 4001 for a reaped session, or a
    /// backend/fork without the method.
    func enqueueActivationFailure(_ error: any Error = HermesError.notConnected) {
        lock.withLock { activations.append(.failure(error)) }
    }
    func setEpoch(_ epoch: String?) { lock.withLock { _epoch = epoch } }
    /// Epoch reported from the moment `activateSession` answers — a backend
    /// restart the fetch-time checks could not have seen.
    func setEpochAfterActivate(_ epoch: String?) {
        lock.withLock { _epochOnActivate = .some(epoch) }
    }

    // MARK: Observation

    var resumedIDs: [String] { lock.withLock { _resumedIDs } }
    var eventsSinceCalls: [(sessionID: String, lastSeen: Int)] {
        lock.withLock { _eventsSinceCalls }
    }
    var activatedIDs: [String] { lock.withLock { _activatedIDs } }
    var closedIDs: [String] { lock.withLock { _closedIDs } }

    // MARK: SessionServicing

    var replayEpoch: String? {
        get async { lock.withLock { _epoch } }
    }

    func createSession(cwd: String?, profile: String?, title: String?) async throws
        -> SessionHandle
    {
        let next: JSONValue? = lock.withLock {
            createAnswers.isEmpty ? nil : createAnswers.removeFirst()
        }
        guard let next, let handle = SessionHandle(result: next) else {
            throw HermesError.malformedResponse("no scripted session.create answer")
        }
        return handle
    }

    func resumeSession(storedID: String, profile: String?) async throws -> SessionHandle {
        lock.withLock { _resumedIDs.append(storedID) }
        if let resumeGate { await resumeGate.arrive() }
        let next: JSONValue? = lock.withLock {
            resumeAnswers.isEmpty ? nil : resumeAnswers.removeFirst()
        }
        guard let next, let handle = SessionHandle(result: next) else {
            throw HermesError.malformedResponse("no scripted session.resume answer")
        }
        return handle
    }

    func eventsSince(sessionID: String, lastSeen: Int) async throws -> EventReplayBatch {
        lock.withLock { _eventsSinceCalls.append((sessionID, lastSeen)) }
        if let eventsSinceGate { await eventsSinceGate.arrive() }
        let next: Result<EventReplayBatch, any Error>? = lock.withLock {
            batches.isEmpty ? nil : batches.removeFirst()
        }
        guard let next else { throw HermesError.malformedResponse("no scripted replay batch") }
        return try next.get()
    }

    func activateSession(sessionID: String) async throws -> LiveSessionSnapshot {
        lock.withLock { _activatedIDs.append(sessionID) }
        if let activateGate { await activateGate.arrive() }
        let next: Result<JSONValue, any Error>? = lock.withLock {
            let answer = activations.isEmpty ? nil : activations.removeFirst()
            // The read happened: anything the epoch changes to from here on
            // is a restart the caller must notice after the fact.
            if case .some(let pending) = _epochOnActivate {
                _epoch = pending
                _epochOnActivate = nil
            }
            return answer
        }
        if let activateReturnGate { await activateReturnGate.arrive() }
        guard let next else {
            throw HermesError.malformedResponse("no scripted session.activate answer")
        }
        // Same failure the live wrapper raises for an unrecognised payload.
        guard let snapshot = LiveSessionSnapshot(result: try next.get()) else {
            throw HermesError.malformedResponse(
                "session.activate did not return a live-session payload")
        }
        return snapshot
    }

    @discardableResult
    func closeSession(sessionID: String) async -> SessionCloseOutcome {
        lock.withLock { _closedIDs.append(sessionID) }
        return .closed
    }
}

/// Speech that records instead of synthesizing. `present()` announces every
/// prompt it shows, so this is also how a test sees how many times a prompt
/// was presented.
final class RecordingSpeech: SpeechPlaying, @unchecked Sendable {
    private let lock = NSLock()
    private var _spoken: [String] = []
    private var _stops = 0

    var spoken: [String] { lock.withLock { _spoken } }

    func startStream() async -> (any SpeechStreaming)? { nil }

    func playFallback(text: String, expectedSequence: Int) async -> Bool {
        lock.withLock { _spoken.append(text) }
        return true
    }

    func stopPlayback() async { lock.withLock { _stops += 1 } }

    var sequence: Int {
        get async { lock.withLock { _stops } }
    }
    var isSpeaking: Bool {
        get async { false }
    }
}

// MARK: Fixtures

/// A connection that is never dialed. The controller only uses it for `rest`
/// (speech/transcription/voice config), all of which the tests replace or
/// never reach; every session RPC goes through `ScriptedSessionService`.
@MainActor
func makeUndialedConnection() -> HermesConnection {
    let endpoint = try! ServerEndpoint.parse("http://127.0.0.1:9").endpoint
    return HermesConnection(endpoint: endpoint, token: nil)
}

@MainActor
func makeController(
    service: ScriptedSessionService,
    speech: RecordingSpeech = RecordingSpeech()
) -> ConversationController {
    ConversationController(
        connection: makeUndialedConnection(),
        profile: nil,
        sessionService: service,
        speech: speech)
}

enum Fixtures {
    /// The envelope `_live_session_payload` always writes, shared by
    /// `session.resume` and `session.activate`. Pending prompt keys are
    /// added only when there is one, which is the backend's own encoding of
    /// "nothing pending" — there is no null form to represent.
    static func livePayload(
        runtimeID: String,
        sessionKey: String,
        startedAt: Double = 1_700_000_000,
        status: String = "idle",
        running: Bool = false,
        pendingApproval: JSONValue? = nil,
        pendingClarify: JSONValue? = nil,
        extra: [String: JSONValue] = [:]
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "session_id": .string(runtimeID),
            "session_key": .string(sessionKey),
            "started_at": .number(startedAt),
            "status": .string(status),
            "running": .bool(running),
            "message_count": .number(0),
            "messages_omitted": .bool(true),
        ]
        if let pendingApproval { object["pending_approval"] = pendingApproval }
        if let pendingClarify { object["pending_clarify"] = pendingClarify }
        for (key, value) in extra { object[key] = value }
        return .object(object)
    }

    /// A `session.resume` / `session.create` result: the live payload plus
    /// the stored-id field the handle re-anchors on.
    static func resumeResult(
        runtimeID: String,
        storedID: String,
        startedAt: Double = 1_700_000_000,
        pendingApproval: JSONValue? = nil,
        pendingClarify: JSONValue? = nil,
        running: Bool = false
    ) -> JSONValue {
        livePayload(
            runtimeID: runtimeID,
            sessionKey: storedID,
            startedAt: startedAt,
            running: running,
            pendingApproval: pendingApproval,
            pendingClarify: pendingClarify,
            extra: ["stored_session_id": .string(storedID)])
    }

    /// A `session.activate` result for the session `resumeResult` returned.
    static func activateResult(
        runtimeID: String,
        sessionKey: String,
        startedAt: Double = 1_700_000_000,
        status: String = "idle",
        pendingApproval: JSONValue? = nil,
        pendingClarify: JSONValue? = nil
    ) -> JSONValue {
        livePayload(
            runtimeID: runtimeID,
            sessionKey: sessionKey,
            startedAt: startedAt,
            status: status,
            pendingApproval: pendingApproval,
            pendingClarify: pendingClarify)
    }

    static func approvalPayload(command: String, requestID: String? = nil) -> JSONValue {
        var object: [String: JSONValue] = [
            "command": .string(command),
            "choices": .array([.string("once"), .string("deny")]),
        ]
        if let requestID { object["request_id"] = .string(requestID) }
        return .object(object)
    }

    static func clarifyPayload(requestID: String, question: String) -> JSONValue {
        .object(["request_id": .string(requestID), "question": .string(question)])
    }

    /// One event frame, in the `{type, session_id, seq, payload}` shape both
    /// the live socket and `session.events.since` carry — so the same fixture
    /// can be delivered either way.
    static func eventParams(
        type: String, sessionID: String, seq: Int, payload: JSONValue = .object([:])
    ) -> JSONValue {
        .object([
            "type": .string(type),
            "session_id": .string(sessionID),
            "seq": .number(Double(seq)),
            "payload": payload,
        ])
    }

    static func approvalRequest(
        sessionID: String, seq: Int, command: String, requestID: String? = nil
    ) -> JSONValue {
        eventParams(
            type: GatewayEvent.Kind.approvalRequest, sessionID: sessionID, seq: seq,
            payload: approvalPayload(command: command, requestID: requestID))
    }

    static func clarifyRequest(
        sessionID: String, seq: Int, requestID: String, question: String
    ) -> JSONValue {
        eventParams(
            type: GatewayEvent.Kind.clarifyRequest, sessionID: sessionID, seq: seq,
            payload: clarifyPayload(requestID: requestID, question: question))
    }

    static func clarifyExpire(sessionID: String, seq: Int, requestID: String) -> JSONValue {
        eventParams(
            type: GatewayEvent.Kind.clarifyExpire, sessionID: sessionID, seq: seq,
            payload: .object(["request_id": .string(requestID)]))
    }

    static func messageComplete(sessionID: String, seq: Int, text: String = "ok") -> JSONValue {
        eventParams(
            type: GatewayEvent.Kind.messageComplete, sessionID: sessionID, seq: seq,
            payload: .object(["text": .string(text)]))
    }

    static func event(_ params: JSONValue) -> GatewayEvent {
        guard let event = GatewayEvent(eventParams: params) else {
            fatalError("malformed event fixture")
        }
        return event
    }

    static func replayBatch(
        _ events: [JSONValue], epoch: String? = "epoch-1", truncated: Bool = false
    ) -> EventReplayBatch {
        var object: [String: JSONValue] = [
            "events": .array(events),
            "truncated": .bool(truncated),
        ]
        if let epoch { object["epoch"] = .string(epoch) }
        return EventReplayBatch(result: .object(object))
    }
}
