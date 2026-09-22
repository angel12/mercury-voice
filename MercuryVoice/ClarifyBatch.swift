import HermesKit

/// Paging state for a batch `clarify` server request (contract ≥ 7,
/// `ClarifyRequest.questions` non-empty), presented one question at a time
/// (issue #125 Task 5).
///
/// Locked questions (`ClarifyRequest.lockedAnswers`) never appear in
/// `pending` — the server already has an answer for them and they are never
/// re-asked — but they are carried in `answers` from the start, so they are
/// still included in the final submission `ConversationController
/// .respondClarify(answers:)` sends.
///
/// A non-batch (single-question) clarify has no paging to do; `ClarifySheet`
/// keeps calling `respondClarify(answer:)` directly for that case and never
/// constructs a `ClarifyBatch`.
struct ClarifyBatch: Equatable {
    private(set) var pending: [ClarifyQuestion]
    private(set) var index = 0
    private(set) var answers: [String: String]

    init(_ request: ClarifyRequest) {
        self.pending = request.questions.filter { request.lockedAnswers[$0.qid] == nil }
        self.answers = request.lockedAnswers
    }

    /// The question on screen, or nil once every pending question has been
    /// answered (or there were none to begin with — every question came in
    /// locked).
    var current: ClarifyQuestion? {
        pending.indices.contains(index) ? pending[index] : nil
    }

    /// 1-based, for "question N of M" — only meaningful while `current` is
    /// non-nil.
    var questionNumber: Int { index + 1 }
    var totalQuestions: Int { pending.count }

    /// Records `answer` ("" = skip) for the current question and advances.
    /// Returns the completed answers dictionary — locked answers included —
    /// once nothing remains; otherwise nil, and the caller re-renders with
    /// the new `current`.
    mutating func recordAndAdvance(_ answer: String) -> [String: String]? {
        guard let question = current else { return answers }
        answers[question.qid] = answer
        index += 1
        return current == nil ? answers : nil
    }

    /// Absorbs locks that arrived while the sheet is up — another client's
    /// `clarify.lock`, seen here through a reconnect's `open_requests`
    /// snapshot (PR #126 review). A newly locked question leaves `pending`
    /// and its locked value replaces whatever the user had recorded for it:
    /// the lock is what the server holds, and never re-asked. Answers the
    /// user already gave for still-open questions are kept, and the page on
    /// screen stays put unless it was the one that locked, in which case the
    /// next unanswered question takes its place.
    ///
    /// Returns the completed answers when that leaves nothing to ask — the
    /// lock took the last open page and every other one is answered — so
    /// the caller submits exactly as `recordAndAdvance` would have.
    mutating func rebase(lockedAnswers: [String: String]) -> [String: String]? {
        answers.merge(lockedAnswers) { _, locked in locked }
        // Pages before `index` are the ones the user has answered; the
        // survivors among them are how far into the new list we are.
        let answered = pending.prefix(index).filter { lockedAnswers[$0.qid] == nil }.count
        pending.removeAll { lockedAnswers[$0.qid] != nil }
        index = answered
        return current == nil ? answers : nil
    }
}
