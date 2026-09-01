# RPC Refusal Reasons Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Plumb JSON-RPC `error.data` through `HermesError.rpcError` so the app reacts to `prompt.submit` refusal reasons (`SESSION_NOT_OWNED`, `MAX_CONCURRENT_SESSIONS`, `SESSION_COORDINATION_UNAVAILABLE`) and error 5072 with spoken-friendly notices instead of reading raw server prose aloud.

**Architecture:** `HermesError.rpcError` gains a third associated value (`data: JSONValue?`) populated at the one construction site in `GatewayClient.handleFrame`. All reason-to-copy mapping lives in `HermesError.errorDescription`, so every display site (voice notice in `ConversationEngine`, `browseError`, dev chat) inherits the friendly line with no per-site changes. The engine's existing `catch { onNotice("Send failed: \(error.localizedDescription)") }` path is untouched.

**Tech Stack:** Swift 5.10+, SwiftPM package `MercuryVoiceCore` (Swift Testing framework: `import Testing`, `@Test`, `#expect`), Xcode multiplatform app target `MercuryVoice`.

**Spec:** https://github.com/angel12/mercury-voice/issues/21 (upstream contract: hermes-agent `hermes_cli/active_sessions.py` as of commits `a5f0fbb262` / `5505042f40`, 2026-08-31)

## Global Constraints

- Reason strings are the upstream contract verbatim: `SESSION_NOT_OWNED`, `MAX_CONCURRENT_SESSIONS`, `SESSION_COORDINATION_UNAVAILABLE`. Never match on the human-readable `message` prose.
- Error codes: `4090` = active-session slot refused (carries `data.reason`), `5072` = session storage (state.db) unavailable (no reason field).
- Spoken-friendly copy must contain no pids, timestamps, file paths, or session ids (it is read aloud by TTS).
- Unknown reasons/codes keep the existing generic `"Hermes error \(code): \(message)"` fallback — the reason set is open.
- Work on branch `claude/issue-21-rpc-error-reasons` off `main`.
- Package tests: `swift test` run from `Packages/MercuryVoiceCore/`. App compile check: `xcodebuild -project MercuryVoice.xcodeproj -scheme MercuryVoice -destination 'platform=macOS' build`.
- Out of scope (deliberately): the issue's optional item 4 (`gateway.capabilities` pre-flight probe). The refusal path now speaks actionable text on first failure; a pre-flight warning is a UX decision for a follow-up issue.

---

### Task 0: Branch setup

**Files:** none

- [ ] **Step 1: Create the branch**

```bash
git checkout main && git pull && git checkout -b claude/issue-21-rpc-error-reasons
```

---

### Task 1: `HermesError` carries `data` and maps refusal reasons to spoken-friendly copy

**Files:**
- Modify: `Packages/MercuryVoiceCore/Sources/HermesKit/HermesError.swift`
- Modify: `Packages/MercuryVoiceCore/Sources/HermesKit/GatewayClient.swift:278-283` (construction site — must change in the same commit or the package won't compile)
- Test: `Packages/MercuryVoiceCore/Tests/HermesKitTests/RPCErrorReasonTests.swift` (new)

**Interfaces:**
- Consumes: `JSONValue` (existing `Sendable, Equatable` enum with `subscript`, `.stringValue`, `.intValue`).
- Produces:
  - `HermesError.rpcError(code: Int, message: String, data: JSONValue?)` — third associated value added; **no default value** (enum cases can't have them), so every construction passes all three.
  - `HermesError.rpcReason: String?` — computed property extracting `data?["reason"]?.stringValue`; `nil` for non-rpcError cases.
  - `HermesError.RPCCode.sessionSlotRefused == 4090`, `HermesError.RPCCode.sessionStorageUnavailable == 5072`.
  - `HermesError.RefusalReason.sessionNotOwned == "SESSION_NOT_OWNED"`, `.maxConcurrentSessions == "MAX_CONCURRENT_SESSIONS"`, `.coordinationUnavailable == "SESSION_COORDINATION_UNAVAILABLE"`.
  - Task 2 relies on exactly these names.

- [ ] **Step 1: Write the failing tests**

Create `Packages/MercuryVoiceCore/Tests/HermesKitTests/RPCErrorReasonTests.swift`:

```swift
import Foundation
import Testing

@testable import HermesKit

/// prompt.submit refusals carry a machine-readable `error.data.reason`
/// (hermes_cli/active_sessions.py: "the reason is the contract; the message
/// is for people"). The app must branch on the reason, never the prose —
/// and the voice notice must be speakable: no pids, paths, or timestamps.
@Suite("RPC refusal reasons")
struct RPCErrorReasonTests {
    /// The raw server prose these errors replace — asserting it stays OUT
    /// of the friendly copy.
    private static let serverProse =
        "Session abc123 already has a live owner (gui, pid 4821, running 3m)."

    private func refusal(_ reason: String) -> HermesError {
        .rpcError(
            code: HermesError.RPCCode.sessionSlotRefused,
            message: Self.serverProse,
            data: .object(["reason": .string(reason)]))
    }

    @Test func reasonIsExtractedFromData() {
        let error = refusal(HermesError.RefusalReason.sessionNotOwned)
        #expect(error.rpcReason == "SESSION_NOT_OWNED")
    }

    @Test func reasonIsNilWithoutData() {
        let error = HermesError.rpcError(code: 4090, message: "busy", data: nil)
        #expect(error.rpcReason == nil)
    }

    @Test func reasonIsNilForOtherCases() {
        #expect(HermesError.notConnected.rpcReason == nil)
    }

    @Test func sessionNotOwnedSpeaksCloseTheOtherApp() {
        let text = refusal(HermesError.RefusalReason.sessionNotOwned)
            .errorDescription ?? ""
        #expect(text.contains("Another app"))
        #expect(!text.contains("pid"))
        #expect(!text.contains("abc123"))
    }

    @Test func maxConcurrentSpeaksTryAgain() {
        let text = refusal(HermesError.RefusalReason.maxConcurrentSessions)
            .errorDescription ?? ""
        #expect(text.contains("session limit"))
        #expect(!text.contains("pid"))
    }

    @Test func coordinationUnavailableNamesTheRegistry() {
        let text = refusal(HermesError.RefusalReason.coordinationUnavailable)
            .errorDescription ?? ""
        #expect(text.contains("registry"))
        // Server prose for this reason names a filesystem path; the spoken
        // notice must not.
        #expect(!text.contains("/"))
    }

    @Test func storageUnavailableByCodeAlone() {
        // 5072 carries no data.reason — mapped by code.
        let error = HermesError.rpcError(
            code: HermesError.RPCCode.sessionStorageUnavailable,
            message: "session storage unavailable: state.db could not be opened — repair state.db",
            data: nil)
        let text = error.errorDescription ?? ""
        #expect(text.contains("storage"))
        #expect(!text.contains("state.db"))
    }

    @Test func unknownReasonFallsBackToGeneric() {
        let error = refusal("SOME_FUTURE_REASON")
        #expect(error.errorDescription == "Hermes error 4090: \(Self.serverProse)")
    }

    @Test func unknownCodeWithoutReasonStaysGeneric() {
        let error = HermesError.rpcError(code: 4007, message: "session not found", data: .null)
        #expect(error.errorDescription == "Hermes error 4007: session not found")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail to compile**

Run: `cd Packages/MercuryVoiceCore && swift test --filter RPCErrorReasonTests`
Expected: COMPILE ERROR — `rpcError` takes 2 associated values; `rpcReason`, `RefusalReason`, `sessionSlotRefused`, `sessionStorageUnavailable` don't exist.

- [ ] **Step 3: Implement in HermesError.swift**

Change the case (line 9):

```swift
    case rpcError(code: Int, message: String, data: JSONValue?)
```

Replace the `.rpcError` branch of `errorDescription` (line 26):

```swift
        case .rpcError(let code, let message, _):
            // Refusal reasons are the machine contract (the prose is server
            // wording that will change); map the known ones to copy that is
            // safe to speak aloud — no pids, paths, or session ids.
            if let reason = rpcReason {
                switch reason {
                case RefusalReason.sessionNotOwned:
                    return
                        "Another app is running this session. Close it there or wait for it to finish, then try again."
                case RefusalReason.maxConcurrentSessions:
                    return "The server is at its session limit. Try again in a moment."
                case RefusalReason.coordinationUnavailable:
                    return
                        "The server can't verify who owns this session. Its active-session registry needs repair — check the backend."
                default:
                    break
                }
            }
            if code == RPCCode.sessionStorageUnavailable {
                return
                    "The server couldn't save your message — its session storage needs repair."
            }
            return "Hermes error \(code): \(message)"
```

Append inside the `HermesError` enum, after the `RPCCode` enum:

```swift
    /// Machine-readable `error.data.reason` values attached to 4090 refusals
    /// (hermes_cli/active_sessions.py). Open set — unknown reasons fall back
    /// to the generic description.
    public enum RefusalReason {
        public static let sessionNotOwned = "SESSION_NOT_OWNED"
        public static let maxConcurrentSessions = "MAX_CONCURRENT_SESSIONS"
        public static let coordinationUnavailable = "SESSION_COORDINATION_UNAVAILABLE"
    }

    /// The `data.reason` of an `.rpcError`, when the server attached one.
    public var rpcReason: String? {
        guard case .rpcError(_, _, let data) = self else { return nil }
        return data?["reason"]?.stringValue
    }
```

Extend `RPCCode` (inside the existing enum, after `sessionBusy`):

```swift
        /// prompt.submit refused: no active-session slot. Carries
        /// `data.reason` (see RefusalReason) on backends ≥ 2026-08-31.
        public static let sessionSlotRefused = 4090
        /// prompt.submit failed: state.db could not be opened; the message
        /// was NOT saved.
        public static let sessionStorageUnavailable = 5072
```

- [ ] **Step 4: Pass `data` at the construction site**

In `GatewayClient.swift` `handleFrame` (line ~278), the only place `.rpcError` is constructed:

```swift
        if let error = frame["error"] {
            cont.resume(
                throwing: HermesError.rpcError(
                    code: error["code"]?.intValue ?? -1,
                    message: error["message"]?.stringValue ?? "unknown error",
                    data: error["data"]))
        } else {
```

(`error["data"]` is already `JSONValue?` — absent key yields `nil`, matching the new parameter.)

- [ ] **Step 5: Run the new tests and the full package suite**

Run: `cd Packages/MercuryVoiceCore && swift test --filter RPCErrorReasonTests`
Expected: PASS (9 tests).

Run: `cd Packages/MercuryVoiceCore && swift test`
Expected: PASS — `HermesConnection.swift:132` uses `if case .rpcError = error` (no bindings), which compiles unchanged; no package test constructs `.rpcError` directly.

- [ ] **Step 6: Commit**

```bash
git add Packages/MercuryVoiceCore/Sources/HermesKit/HermesError.swift \
        Packages/MercuryVoiceCore/Sources/HermesKit/GatewayClient.swift \
        Packages/MercuryVoiceCore/Tests/HermesKitTests/RPCErrorReasonTests.swift
git commit -m "feat(hermeskit): carry error.data through rpcError and speak refusal reasons (#21)"
```

---

### Task 2: App target follows the new case shape; README documents the contract

**Files:**
- Modify: `MercuryVoice/AppModel.swift:440` (pattern match gains a third wildcard)
- Modify: `README.md` (one bullet added to "Key protocol facts honored")

**Interfaces:**
- Consumes: `HermesError.rpcError(code:message:data:)` (three associated values) and `HermesError.RPCCode.methodNotFound` from Task 1.
- Produces: nothing new — this task makes the app target compile and documents the behavior.

- [ ] **Step 1: Fix the pattern match in AppModel.swift**

Line 440, the older-backend `projects.*` fallback. The two-value pattern no longer compiles against the three-value case:

```swift
            if case .rpcError(HermesError.RPCCode.methodNotFound, _, _) = error {
```

(Only this one site: `HermesConnection.swift:132` binds nothing and needs no change; no other file pattern-matches `.rpcError` with bindings.)

- [ ] **Step 2: Verify the app target builds**

Run: `xcodebuild -project MercuryVoice.xcodeproj -scheme MercuryVoice -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Add the protocol-fact bullet to README.md**

In the "Key protocol facts honored (verified against the hermes-agent source):" list, after the `prompt.submit` bullet ("returns immediately; completion is `message.complete` only (busy gate)."), insert:

```markdown
- `prompt.submit` refusals branch on the machine-readable `error.data.reason` (`SESSION_NOT_OWNED` / `MAX_CONCURRENT_SESSIONS` / `SESSION_COORDINATION_UNAVAILABLE`, backends ≥ 2026-08-31) — never on the message prose — and error 5072 (state.db unavailable, message not saved) maps by code; each gets a spoken-friendly notice, with a generic fallback for unknown reasons.
```

- [ ] **Step 4: Run the full package suite once more**

Run: `cd Packages/MercuryVoiceCore && swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MercuryVoice/AppModel.swift README.md
git commit -m "fix(app): adopt three-value rpcError pattern; document refusal-reason contract (#21)"
```

---

### Task 3: Manual verification checklist (hand to Spencer)

**Files:** none — Spencer runs his own backend; no backend is spawned for verification.

- [ ] **Step 1: Post the checklist as a PR comment / hand over in chat**

Manual test checklist against a live hermes-agent ≥ 2026-08-31:

1. **SESSION_NOT_OWNED** — start a turn on a session from `hermes chat` (CLI, separate pid), then speak a prompt to the same session in Mercury Voice. Expect the notice "Send failed: Another app is running this session…" and the mic re-arming (idle), not raw pid prose.
2. **5072** — (only if convenient) make `state.db` unopenable (`chmod 000`) on a scratch profile, speak a prompt. Expect "…couldn't save your message — its session storage needs repair." Restore permissions after.
3. **Old backend regression** — against a pre-2026-08-31 backend (no `data.reason`), force any RPC error (e.g. resume a bogus session id) and confirm the generic "Hermes error N: …" text still appears.
4. **Older-backend browse fallback** — confirm Browse still degrades to the flat session list on a backend without `projects.*` (the `methodNotFound` pattern edited in Task 2).

---

## Self-Review

- **Spec coverage:** Issue item 1 (data through rpcError) → Task 1 steps 3–4. Item 2 (reason constants) → Task 1 step 3 (`RefusalReason`, plus the two new `RPCCode`s). Item 3 (spoken-friendly mapping on the submit failure path) → Task 1 step 3; the engine's `onNotice("Send failed: \(error.localizedDescription)")` at `ConversationEngine.swift:414`/`768` inherits it with no engine change. Item 4 (capabilities pre-flight) → explicitly out of scope (Global Constraints) as the issue marked it optional.
- **Placeholder scan:** none — all steps carry exact code, paths, and commands.
- **Type consistency:** `rpcError(code:message:data:)` used identically in Task 1 (construction, tests) and Task 2 (pattern). Constant names (`RefusalReason.sessionNotOwned` etc., `RPCCode.sessionSlotRefused`, `RPCCode.sessionStorageUnavailable`) match between implementation and tests.
