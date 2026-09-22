import HermesKit
import Testing

@testable import MercuryVoice

/// `ClarifyBatch` paging state (issue #125). `ClarifySheet` has no view test
/// seam, so the decisions it makes — how a batch absorbs locks that arrive
/// while it is on screen (PR #126 review) — live here as pure value logic.
@Suite("ClarifyBatch")
struct ClarifyBatchTests {
    private func request(
        qids: [String] = ["q1", "q2", "q3"], locked: [String: String] = [:]
    ) -> ClarifyRequest {
        var request = ClarifyRequest(
            payload: .object(["request_id": .string("srq-b1")]), sessionID: "rt1")!
        request.serverRequestID = "srq-b1"
        request.questions = qids.map {
            ClarifyQuestion(qid: $0, question: "\($0)?", choices: [], multiSelect: false)
        }
        request.lockedAnswers = locked
        return request
    }

    @Test("rebase drops a newly locked question and keeps the user's other answers")
    func rebaseDropsLockedQuestionKeepsAnswers() {
        var batch = ClarifyBatch(request())
        #expect(batch.recordAndAdvance("a1") == nil)  // q1 answered, now on q2
        #expect(batch.current?.qid == "q2")

        let completed = batch.rebase(lockedAnswers: ["q2": "locked2"])

        #expect(completed == nil)
        #expect(batch.pending.map(\.qid) == ["q1", "q3"])
        #expect(batch.current?.qid == "q3")
        #expect(batch.questionNumber == 2)
        #expect(batch.totalQuestions == 2)
        #expect(batch.answers == ["q1": "a1", "q2": "locked2"])
    }

    @Test("rebase keeps the page on screen when a question behind it locks")
    func rebaseKeepsCurrentPage() {
        var batch = ClarifyBatch(request())
        _ = batch.recordAndAdvance("a1")
        _ = batch.recordAndAdvance("a2")  // on q3
        _ = batch.rebase(lockedAnswers: ["q1": "locked1"])

        #expect(batch.current?.qid == "q3")
        #expect(batch.answers == ["q1": "locked1", "q2": "a2"])
    }

    @Test("a locked value overrides an answer the user already gave")
    func lockedValueIsAuthoritative() {
        var batch = ClarifyBatch(request())
        _ = batch.recordAndAdvance("mine")
        _ = batch.rebase(lockedAnswers: ["q1": "theirs"])

        #expect(batch.answers["q1"] == "theirs")
        #expect(batch.current?.qid == "q2")
    }

    @Test("rebase returns the completed answers when the lock took the last open page")
    func rebaseCompletesWhenNothingIsLeft() {
        var batch = ClarifyBatch(request())
        _ = batch.recordAndAdvance("a1")
        _ = batch.recordAndAdvance("a2")  // on q3, the final page

        let completed = batch.rebase(lockedAnswers: ["q3": "locked3"])

        #expect(completed == ["q1": "a1", "q2": "a2", "q3": "locked3"])
        #expect(batch.current == nil)
    }
}
