import Foundation

/// Spoken stop-command detection — a faithful port of the desktop's
/// `lib/voice-stop-word.ts`.
///
/// Full-utterance match only: "stop the docker container" must pass through
/// as a prompt.
public enum StopWords {
    static let stopPhrases: Set<String> = [
        "stop",
        "stop listening",
        "stop it",
        "stop please",
        "please stop",
        "stop stop",
        "that is all",
        "that's all",
        "never mind",
        "nevermind",
        "end conversation",
        "end the conversation",
        "goodbye",
        "good bye",
        "bye",
        "cancel",
    ]

    /// Address prefixes stripped before matching; order significant, only the
    /// first hit is stripped.
    static let addressPrefixes = [
        "hey mercury",
        "mercury",
        "hey hermes",
        "hermes",
        "ok",
        "okay",
        "hey",
    ]

    /// Lowercase, strip `.,!?;:…` (as spaces), collapse whitespace, trim.
    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        var out = ""
        out.reserveCapacity(lowered.count)
        for char in lowered {
            if ".,!?;:…".contains(char) {
                out.append(" ")
            } else {
                out.append(char)
            }
        }
        return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Strip the first matching address prefix ("hey hermes stop" → "stop").
    /// A bare address word alone is never a stop command.
    static func stripAddress(_ normalized: String) -> String {
        for prefix in addressPrefixes {
            if normalized == prefix { continue }
            if normalized.hasPrefix(prefix + " ") {
                return String(normalized.dropFirst(prefix.count + 1))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return normalized
    }

    public static func isStopCommand(_ transcript: String) -> Bool {
        let normalized = normalize(transcript)
        guard !normalized.isEmpty else { return false }
        return stopPhrases.contains(normalized) || stopPhrases.contains(stripAddress(normalized))
    }
}
