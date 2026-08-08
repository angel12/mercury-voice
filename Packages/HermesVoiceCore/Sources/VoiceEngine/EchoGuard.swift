import Foundation

/// Last line of defense against the barge-in feedback loop (issue #12): when
/// the mic hears the speakers, the captured "interruption" transcribes to the
/// agent's own words. Submitting that spawns another reply, which echoes
/// again — forever. A transcript made almost entirely of words from the reply
/// being spoken is self-echo, not the user.
///
/// No desktop counterpart — the browser's getUserMedia echo cancellation
/// makes this unreachable there.
public enum EchoGuard {
    /// Fraction of transcript words that must appear in the reply. STT of an
    /// echo mishears the odd word, so this sits below 1; a genuine
    /// interruption shares far fewer.
    private static let matchThreshold = 0.8

    public static func isLikelyEcho(transcript: String, reply: String) -> Bool {
        let transcriptTokens = tokens(transcript)
        guard !transcriptTokens.isEmpty else { return false }
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
