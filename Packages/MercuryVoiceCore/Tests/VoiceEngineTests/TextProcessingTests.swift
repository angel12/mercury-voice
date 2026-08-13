import Foundation
import Testing

@testable import VoiceEngine

@Suite("Stop words")
struct StopWordTests {
    @Test func matchesBareStopPhrases() {
        #expect(StopWords.isStopCommand("stop"))
        #expect(StopWords.isStopCommand("Stop."))
        #expect(StopWords.isStopCommand("STOP LISTENING"))
        #expect(StopWords.isStopCommand("that's all"))
        #expect(StopWords.isStopCommand("That is all!"))
        #expect(StopWords.isStopCommand("never mind"))
        #expect(StopWords.isStopCommand("nevermind"))
        #expect(StopWords.isStopCommand("end the conversation"))
        #expect(StopWords.isStopCommand("Goodbye"))
        #expect(StopWords.isStopCommand("bye"))
        #expect(StopWords.isStopCommand("cancel"))
    }

    @Test func stripsAddressPrefixes() {
        #expect(StopWords.isStopCommand("hey mercury stop"))
        #expect(StopWords.isStopCommand("Mercury, stop."))
        #expect(StopWords.isStopCommand("hey hermes stop"))
        #expect(StopWords.isStopCommand("Hermes, stop."))
        #expect(StopWords.isStopCommand("okay stop"))
        #expect(StopWords.isStopCommand("ok that's all"))
        #expect(StopWords.isStopCommand("hey stop listening"))
    }

    @Test func directPhrasesWithUnstrippablePrefixWords() {
        // "please" isn't an address prefix; "please stop" matches directly.
        #expect(StopWords.isStopCommand("please stop"))
        #expect(StopWords.isStopCommand("stop please"))
    }

    @Test func doesNotMatchSubstantiveRequests() {
        #expect(!StopWords.isStopCommand("stop the docker container"))
        #expect(!StopWords.isStopCommand("cancel the meeting tomorrow"))
        #expect(!StopWords.isStopCommand("how do I stop the build?"))
        #expect(!StopWords.isStopCommand("goodbye emails should be drafted"))
    }

    @Test func doesNotMatchBareAddressOrEmpty() {
        #expect(!StopWords.isStopCommand("mercury"))
        #expect(!StopWords.isStopCommand("hermes"))
        #expect(!StopWords.isStopCommand("hey"))
        #expect(!StopWords.isStopCommand(""))
        #expect(!StopWords.isStopCommand("   "))
    }

    @Test func onlyOnePrefixIsStripped() {
        #expect(!StopWords.isStopCommand("ok hey stop"))
    }

    @Test func normalizationStripsEllipsisAndPunctuation() {
        #expect(StopWords.isStopCommand("stop…"))
        #expect(StopWords.isStopCommand("stop, stop"))
    }
}

@Suite("Speech text sanitizer")
struct SpeechTextTests {
    @Test func stripsFencedCode() {
        let out = SpeechText.sanitizeForSpeech(
            "Here you go:\n```swift\nlet x = 1\n```\nDone.")
        #expect(out.contains("code block omitted"))
        #expect(!out.contains("let x"))
    }

    @Test func unterminatedFenceIsStripped() {
        let out = SpeechText.sanitizeForSpeech("Look:\n```python\nprint('hi')")
        #expect(out.contains("code block omitted"))
        #expect(!out.contains("print"))
    }

    @Test func linksKeepTextURLsBecomeLink() {
        let out = SpeechText.sanitizeForSpeech(
            "See [the docs](https://example.com/a) or https://raw.example.com/x?q=1 now")
        #expect(out.contains("the docs"))
        #expect(!out.contains("example.com"))
        #expect(out.contains("link"))
    }

    @Test func inlineCodeKeepsContent() {
        #expect(SpeechText.sanitizeForSpeech("run `swift build` now") == "run swift build now")
    }

    @Test func headingsAndEmphasisStripped() {
        let out = SpeechText.sanitizeForSpeech("# Title\n\nSome **bold** and _italic_ text")
        #expect(out.contains("Title"))
        #expect(!out.contains("#"))
        #expect(!out.contains("*"))
        #expect(out.contains("bold"))
    }

    @Test func stripsMarkdownTables() {
        let text = """
            Results:

            | Name | Value |
            | --- | ----: |
            | a | 1 |
            | b | 2 |

            That's the summary.
            """
        let out = SpeechText.sanitizeForSpeech(text)
        #expect(!out.contains("Value"))
        #expect(out.contains("Results"))
        #expect(out.contains("summary"))
    }

    @Test func doesNotTreatPlainPipesAsTable() {
        let out = SpeechText.sanitizeForSpeech("Use a | b to pipe\nsecond line here")
        #expect(out.contains("Use a | b to pipe"))
    }

    @Test func paragraphBreaksBecomeSentenceBoundaries() {
        #expect(
            SpeechText.sanitizeForSpeech("First paragraph\n\nSecond one")
                == "First paragraph. Second one")
        // Already-punctuated ends don't get doubled periods.
        #expect(
            SpeechText.sanitizeForSpeech("Done!\n\nNext part")
                == "Done! Next part")
    }

    @Test func stripsEmoji() {
        let out = SpeechText.sanitizeForSpeech("Great work 🎉 team ✅")
        #expect(out == "Great work team")
    }

    @Test func stripsThinkingPrefix() {
        let out = SpeechText.sanitizeForSpeech("Thinking... the answer is 4")
        #expect(out == "the answer is 4")
    }

    @Test func bulletsAtStartStripped() {
        let out = SpeechText.sanitizeForSpeech("- first item")
        #expect(out == "first item")
    }
}

@Suite("WAV encoder")
struct WAVEncoderTests {
    @Test func producesValidHeader() {
        let samples = [Float](repeating: 0.25, count: 16000)
        let data = WAVEncoder.encode(samples: samples, sampleRate: 16000)
        #expect(data.count == 44 + 16000 * 2)
        #expect(String(data: data.prefix(4), encoding: .ascii) == "RIFF")
        #expect(String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WAVE")
        // Sample rate little-endian at offset 24.
        let rate = data.subdata(in: 24..<28).withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(UInt32(littleEndian: rate) == 16000)
    }

    @Test func downsamplesFrom48k() {
        let samples = [Float](repeating: 0.1, count: 48000)  // 1 second
        let data = WAVEncoder.encode(samples: samples, sampleRate: 48000)
        let frames = (data.count - 44) / 2
        #expect(abs(frames - 16000) < 10)
    }
}

@Suite("Echo guard")
struct EchoGuardTests {
    private let reply = "The weather today is sunny and warm, around seventy degrees."

    @Test func verbatimEchoMatches() {
        #expect(EchoGuard.isLikelyEcho(transcript: "the weather today is sunny", reply: reply))
    }

    @Test func echoWithOneMisheardWordMatches() {
        // 4 of 5 words present (0.8): STT mangling a word must not defeat it.
        #expect(
            EchoGuard.isLikelyEcho(transcript: "the whether today is sunny", reply: reply))
    }

    @Test func genuineInterruptionDoesNotMatch() {
        #expect(
            !EchoGuard.isLikelyEcho(transcript: "no, do it differently please", reply: reply))
    }

    @Test func punctuationAndCaseAreIgnored() {
        #expect(
            EchoGuard.isLikelyEcho(transcript: "Sunny — and WARM!", reply: reply))
    }

    @Test func emptyTranscriptIsNotEcho() {
        #expect(!EchoGuard.isLikelyEcho(transcript: "  ", reply: reply))
        #expect(!EchoGuard.isLikelyEcho(transcript: "hello", reply: ""))
    }
}

@Suite("Barge detector")
struct BargeDetectorTests {
    private let hop = Duration.milliseconds(50)

    /// Run `count` hops at a constant level; returns first non-quiet verdict.
    private func feed(
        _ detector: inout BargeDetector, level: Double, hops: Int, playing: Bool,
        from start: Duration
    ) -> (verdict: BargeDetector.Verdict, at: Duration)? {
        var now = start
        for _ in 0..<hops {
            let verdict = detector.process(level: level, at: now, playing: playing)
            if verdict != .quiet && verdict != .capturing { return (verdict, now) }
            now += hop
        }
        return nil
    }

    @Test func tripsOnSustainedSpeechAfterCalibration() {
        var detector = BargeDetector()
        // 500 ms of quiet calibration.
        #expect(feed(&detector, level: 0.01, hops: 10, playing: false, from: .zero) == nil)
        // Sustained loud speech: must trip within ~600 ms.
        let tripped = feed(
            &detector, level: 0.3, hops: 12, playing: false, from: .milliseconds(500))
        #expect(tripped?.verdict == .tripped)
    }

    @Test func briefSpikeDoesNotTrip() {
        var detector = BargeDetector()
        _ = feed(&detector, level: 0.01, hops: 10, playing: false, from: .zero)
        var now = Duration.milliseconds(500)
        // Two loud hops (100 ms) then quiet — under the 300 ms majority.
        for _ in 0..<2 {
            #expect(detector.process(level: 0.5, at: now, playing: false) == .quiet)
            now += hop
        }
        let after = feed(&detector, level: 0.01, hops: 10, playing: false, from: now)
        #expect(after == nil)
    }

    @Test func playbackOnsetGraceSuppressesTrip() {
        var detector = BargeDetector()
        _ = feed(&detector, level: 0.01, hops: 10, playing: false, from: .zero)
        // Playback starts; echo-ish level right at onset must not count for
        // the first 500 ms.
        var now = Duration.milliseconds(500)
        for _ in 0..<9 {  // 450 ms inside grace
            let verdict = detector.process(level: 0.3, at: now, playing: true)
            #expect(verdict == .quiet)
            now += hop
        }
        // After grace, speech OVER the learned 0.3 echo floor does trip.
        let tripped = feed(&detector, level: 0.6, hops: 12, playing: true, from: now)
        #expect(tripped?.verdict == .tripped)
    }

    @Test func sustainedPlaybackEchoNeverTrips() {
        // Issue #12's loop scenario: speaker output leaking into the mic at a
        // steady speech-like level for the whole reply must not barge.
        var detector = BargeDetector()
        _ = feed(&detector, level: 0.01, hops: 10, playing: false, from: .zero)
        let result = feed(
            &detector, level: 0.3, hops: 100, playing: true, from: .milliseconds(500))
        #expect(result == nil)
    }

    @Test func speechOverPlaybackEchoTrips() {
        var detector = BargeDetector()
        _ = feed(&detector, level: 0.01, hops: 10, playing: false, from: .zero)
        // A second of steady echo, then the user talks over it.
        #expect(
            feed(&detector, level: 0.2, hops: 20, playing: true, from: .milliseconds(500))
                == nil)
        let tripped = feed(
            &detector, level: 0.5, hops: 12, playing: true, from: .milliseconds(1500))
        #expect(tripped?.verdict == .tripped)
    }

    @Test func playbackClampRaisesTrigger() {
        var detector = BargeDetector()
        _ = feed(&detector, level: 0.01, hops: 10, playing: false, from: .zero)
        // 0.1 exceeds the quiet trigger (0.075) but is under the playback
        // minimum (0.14) — with playback active it must not trip, even well
        // past the grace window.
        let result = feed(
            &detector, level: 0.1, hops: 40, playing: true, from: .milliseconds(500))
        #expect(result == nil)
    }

    @Test func endpointsAfterTrailingSilence() {
        var detector = BargeDetector()
        _ = feed(&detector, level: 0.01, hops: 10, playing: false, from: .zero)
        let tripped = feed(
            &detector, level: 0.3, hops: 12, playing: false, from: .milliseconds(500))
        let trippedAt = try! #require(tripped).at
        // Quiet after the trip: capture ends after 1250 ms of silence.
        var now = trippedAt + hop
        var ended: Duration?
        for _ in 0..<40 {
            if detector.process(level: 0.01, at: now, playing: false) == .captureEnded {
                ended = now
                break
            }
            now += hop
        }
        let end = try! #require(ended)
        #expect(end - trippedAt >= .milliseconds(1250))
        #expect(end - trippedAt <= .milliseconds(1500))
    }

    @Test func endpointHonorsCustomUtteranceSilence() {
        // Issue #24: the user's end-of-turn setting stretches the barge
        // capture endpoint too.
        var detector = BargeDetector(utteranceSilence: .milliseconds(2500))
        _ = feed(&detector, level: 0.01, hops: 10, playing: false, from: .zero)
        let tripped = feed(
            &detector, level: 0.3, hops: 12, playing: false, from: .milliseconds(500))
        let trippedAt = try! #require(tripped).at
        var now = trippedAt + hop
        var ended: Duration?
        for _ in 0..<80 {
            if detector.process(level: 0.01, at: now, playing: false) == .captureEnded {
                ended = now
                break
            }
            now += hop
        }
        let end = try! #require(ended)
        #expect(end - trippedAt >= .milliseconds(2500))
        #expect(end - trippedAt <= .milliseconds(2750))
    }
}

@Suite("Turn silence preference")
struct TurnSilencePreferenceTests {
    /// Serialized through one test to avoid parallel writers on the shared
    /// UserDefaults key; restores whatever was stored before.
    @Test func defaultsAndClamping() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: TurnSilencePreference.key)
        defer {
            if let saved {
                defaults.set(saved, forKey: TurnSilencePreference.key)
            } else {
                defaults.removeObject(forKey: TurnSilencePreference.key)
            }
        }

        defaults.removeObject(forKey: TurnSilencePreference.key)
        #expect(TurnSilencePreference.seconds == TurnSilencePreference.defaultSeconds)
        #expect(TurnSilencePreference.duration == VoiceConstants.endOfTurnSilence)

        TurnSilencePreference.seconds = 2.0
        #expect(TurnSilencePreference.seconds == 2.0)
        #expect(TurnSilencePreference.duration == .seconds(2))

        // Out-of-range values clamp on both write and read.
        TurnSilencePreference.seconds = 99
        #expect(TurnSilencePreference.seconds == TurnSilencePreference.range.upperBound)
        defaults.set(0.01, forKey: TurnSilencePreference.key)
        #expect(TurnSilencePreference.seconds == TurnSilencePreference.range.lowerBound)
    }
}
