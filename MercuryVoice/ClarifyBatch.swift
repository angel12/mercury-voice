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
    let pending: [ClarifyQuestion]
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
}
