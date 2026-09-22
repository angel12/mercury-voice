import Foundation
import HermesKit

/// The gateway session RPCs `ConversationController` calls.
///
/// Seamed for the same reason `AppDependencies` seams the auth surface
/// (issue #81): the reconnect path is a sequence of round-trips whose
/// *ordering* is the behaviour under test — `session.resume` snapshots the
/// session, `session.events.since` returns everything newer, and
/// `session.activate` re-reads the prompt registry after that. A test can
/// only pin that ordering if it can script each answer and hold each call
/// open, which a live `HermesConnection` cannot offer.
///
/// The prompt responses (`approval.respond`, `clarify.respond` and the
/// contract-7 `request.answer`, issue #125) are here too: which of them a
/// sheet is answered through is the behaviour under test there, and a test
/// can only observe it — and hold the reply open — through this seam.
///
/// The connection itself stays concrete: `rest` (speech, transcription,
/// voice config) and the tracker's submit/interrupt closure are not part of
/// this seam and still go straight to `HermesConnection`.
protocol SessionServicing: Sendable {
    /// `replay_epoch` of the current socket; nil while disconnected or
    /// against a backend without the replay contract.
    var replayEpoch: String? { get async }

    func createSession(cwd: String?, profile: String?, title: String?) async throws -> SessionHandle
    func resumeSession(storedID: String, profile: String?) async throws -> SessionHandle
    func eventsSince(sessionID: String, lastSeen: Int) async throws -> EventReplayBatch
    func activateSession(sessionID: String) async throws -> LiveSessionSnapshot

    @discardableResult
    func closeSession(sessionID: String) async -> SessionCloseOutcome

    func respondApproval(sessionID: String, choice: String) async throws
    func respondClarify(requestID: String, answer: String) async throws
    func answerServerRequest(id: String, result: JSONValue) async throws -> ServerRequestAnswer

    /// `POST /api/audio/tts-lease` (contract ≥ 7) — acquire/release this
    /// conversation's claim on the server-side TTS model. Best-effort: never
    /// throws, so the controller can fire it without gating on the result.
    /// Part of this seam (unlike the rest of `rest`) because *whether* and
    /// *how many times* it fires is exactly the acquire/release-once
    /// behaviour under test here.
    func ttsLease(_ lease: String, active: Bool, profile: String?) async
}

extension HermesConnection: SessionServicing {}
