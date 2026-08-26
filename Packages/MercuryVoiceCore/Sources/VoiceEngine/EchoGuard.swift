import Foundation

/// Last line of defense against the barge-in feedback loop (issue #12): when
/// the mic hears the speakers, the captured "interruption" transcribes to the
/// agent's own words. Submitting that spawns another reply, which echoes
/// again — forever. A transcript made almost entirely of words from the reply
/// being spoken is self-echo, not the user.
///
/// Two knobs work together (issue #8): transcripts under `minimumTokens` are
/// never echo, and everything longer is echo once `matchThreshold` of its
/// words appear in the reply. The floor protects short genuine interruptions;
/// with those exempt, the threshold can sit low enough to catch mistranscribed
/// echoes of full sentences.
///
/// No desktop counterpart — the browser's getUserMedia echo cancellation
/// makes this unreachable there.
public enum EchoGuard {
    /// Transcripts with fewer tokens than this are never classified as echo
    /// (issue #8). A real echo capture is a fragment of the agent's sentence
    /// and almost always runs longer; a 1–2 word utterance is far more likely
    /// a genuine interruption ("stop", "no", a term the agent just said), and
    /// losing a real turn is worse than letting one short echo through.
    private static let minimumTokens = 3

    /// Fraction of transcript words that must appear in the reply. STT of an
    /// echo mishears the odd word, so this sits below 1; a genuine
    /// interruption shares far fewer. With `minimumTokens` exempting short
    /// transcripts, 0.7 can afford to catch real echoes whose STT misheard
    /// more words (6 of 8 matched = 0.75 previously passed through and got
    /// re-submitted). At 3 tokens, 3 * 0.7 = 2.1 still requires all three to
    /// match, so short genuine interruptions keep their protection.
    private static let matchThreshold = 0.7

    public static func isLikelyEcho(transcript: String, reply: String) -> Bool {
        let transcriptTokens = tokens(transcript)
        guard transcriptTokens.count >= minimumTokens else { return false }
        let replyTokens = Set(tokens(reply))
        guard !replyTokens.isEmpty else { return false }
        let matched = transcriptTokens.lazy.filter(replyTokens.contains).count
        return Double(matched) >= Double(transcriptTokens.count) * matchThreshold
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}
