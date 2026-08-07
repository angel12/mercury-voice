# Hermes Voice

A native SwiftUI voice-conversation client for [Hermes Agent](https://github.com/NousResearch/hermes-agent) — macOS 14+ and iOS 17+ from one multiplatform Xcode project. It speaks the same JSON-RPC WebSocket protocol as the Hermes desktop app (loopback token mode, or gated basic-auth mode with username/password) and replicates its hands-free voice loop: listen → transcribe → submit → speak the streamed reply → re-arm, with full-duplex barge-in and spoken stop words.

## Building

Open `HermesVoice.xcodeproj` in Xcode 16+ and run the `HermesVoice` scheme, or:

```bash
xcodebuild -project HermesVoice.xcodeproj -scheme HermesVoice -destination 'platform=macOS' build
```

```bash
xcodebuild -project HermesVoice.xcodeproj -scheme HermesVoice -destination 'generic/platform=iOS Simulator' build
```

Unit tests (65 tests: state machine, barge detector, sanitizer, stop words, protocol models):

```bash
cd Packages/HermesVoiceCore && swift test
```

## Architecture

```
Packages/HermesVoiceCore/
├── HermesKit      # protocol layer — no UI, no audio
│   ├── ServerEndpoint      URL/token parsing (accepts pasted dashboard URLs)
│   ├── HermesAuthenticator credential state: token header vs Bearer, password
│   │                       login, /auth/native/refresh rotation, ws-tickets
│   ├── GatewayClient       one /api/ws JSON-RPC socket: correlation + event demux
│   ├── HermesConnection    reconnect supervisor (full-jitter backoff, stable event stream)
│   ├── SessionAPI          session.create/resume, prompt.submit, projects.tree,
│   │                       approval.respond / clarify.respond
│   ├── RESTClient          /api/status, /api/profiles, sessions, transcribe, speak
│   └── KeychainTokenStore  per-server credentials (session token or password session)
├── VoiceEngine    # audio + the conversation state machine
│   ├── ConversationEngine  idle→listening→transcribing→thinking→speaking→re-arm
│   │                       (port of the desktop's use-voice-conversation.ts;
│   │                       generic over Clock, fully unit-tested with fakes)
│   ├── AgentTurnTracker    synthesizes reply "bubbles" from message.* events,
│   │                       busy tracking, spoken watermark
│   ├── MicRecorder         AVAudioEngine capture + VAD (0.075 / 1250ms / 12s / 60s)
│   ├── BargeDetector/-Monitor  noise-floor calibration, 300ms·80% majority trip,
│   │                       playback clamp 0.14–0.37, 5s pre-roll, 1250ms endpoint
│   ├── SpeakStreamSession  /api/audio/speak-stream WS → int16 PCM → gap-free player
│   ├── HermesSpeechOutput  stream-first, POST /api/audio/speak fallback, stop/sequence
│   ├── SpeechText          TTS sanitizer (tables/fences/links/emoji, desktop parity)
│   └── StopWords           full-utterance match with address-prefix stripping
HermesVoice/       # SwiftUI app: Connect → Browse (profiles+projects) → Conversation
```

Key protocol facts honored (verified against the hermes-agent source):

- **Two-ID model** — every RPC takes the ephemeral runtime `session_id`; reconnects re-`session.resume` by the durable stored id and re-anchor to the result's `resumed` field.
- `prompt.submit` returns immediately; completion is `message.complete` only (busy gate).
- The speak-stream gets `{"done": true}` only when the reply is non-pending **and** the turn is no longer busy, so trailing narration isn't cut off; `{"type":"fallback"}` reroutes to whole-clip TTS.
- Empty transcript = silence → quietly re-listen (never an error toast).
- `approval.request` is session-keyed (no request_id); `clarify.request`/`clarify.expire` correlate by `request_id`; both pause the voice loop and speak a short notice.
- Quiet sockets during a busy turn are healthy (server disables WS pings on loopback binds) — no read timeout.
- First submit after a barge-in carries `interrupted: true` (120 s latch, like the desktop).

## Connecting

1. On the machine running Hermes: `hermes serve` — it prints/opens `http://127.0.0.1:<port>/?token=...`.
2. Paste that whole URL into the app's server field; the token is lifted out automatically. Credentials persist in the Keychain per server and the app auto-reconnects on next launch.
3. **iPhone → Mac:** a loopback-bound backend refuses non-local peers. Use `tailscale serve` on the Mac (proxies from loopback, so token mode keeps working), an SSH tunnel, or a gated bind with basic auth (below).
4. **Gated binds (username & password):** for a non-loopback bind, configure the backend's basic-auth provider (`dashboard.basic_auth.username` + `password` or `password_hash` in `config.yaml`, or the `HERMES_DASHBOARD_BASIC_AUTH_*` env vars). Connect with just the server address — the app detects the gate, prompts for the username/password, and signs in. Under the hood: `POST /auth/password-login` mints access/refresh tokens (lifted from the session cookies into the Keychain), REST authenticates with `Authorization: Bearer`, expired access tokens rotate via `/auth/native/refresh`, and each WebSocket dial mints a single-use 30 s ticket via `POST /api/auth/ws-ticket`. OAuth-only gated servers are still unsupported.

## Manual verification checklist (live backend)

Milestone 1 — connect + browse:
- [ ] `/api/status` probe shows version; bad token → clear "token rejected" message
- [ ] Gateway connects, `gateway.ready` received (app reaches the browse screen)
- [ ] Profiles list renders (name/model/provider/skills; default marked); can take ~30 s on big skill trees
- [ ] Projects tree shows explicit projects, repo projects, Home bucket; recents exclude scoped sessions
- [ ] Switching profile refreshes projects + recents

Milestone 1b — basic auth (gated bind, `dashboard.basic_auth` configured):
- [ ] Connect with just the address → sign-in form appears (provider display name shown)
- [ ] Wrong password → "Invalid username or password" (and 429 after ~10 rapid tries)
- [ ] Correct credentials → browse screen; kill + relaunch app → auto-reconnects without prompting
- [ ] Voice conversation works end-to-end (WS + speak-stream mint per-dial tickets)
- [ ] Backend restart (no configured `secret`) invalidates sessions → app returns to the sign-in form with "session expired", username prefilled
- [ ] Loopback token servers still connect exactly as before (legacy keychain items migrate silently)

Milestone 2 — text path (keyboard icon in the conversation header):
- [ ] New conversation in a project → `session.info` shows the right cwd/project
- [ ] Typed prompt streams a reply; tool ticker shows `tool.start` names
- [ ] Approval-requiring command surfaces the sheet; each choice unblocks the turn
- [ ] Backend restart mid-conversation → app reconnects and resumes by stored id ("Reconnected." notice)

Milestones 3–5 — voice:
- [ ] Reply is spoken via speak-stream (streaming TTS provider) with live captions
- [ ] With edge-tts (non-streaming): fallback path plays the whole clip
- [ ] Silence-only turn re-listens quietly after ~12 s; "stop" / "hey hermes stop" ends the conversation; "stop the docker container" goes through as a prompt
- [ ] Barge-in during speech stops playback ≤ ~0.5 s, captures your sentence from the first syllable (pre-roll), submits with the interrupted note
- [ ] Barge-in during generation also sends `session.interrupt`
- [ ] Stop button ends speech and does *not* re-arm; mute/unmute behaves
- [ ] iOS: conversation survives screen lock (background audio) and AirPods route changes

macOS mute hotkey (Settings, ⌘,):
- [ ] ⌘⇧M toggles mute during a conversation (default, app focused); Conversation menu shows the shortcut and flips Mute/Unmute
- [ ] Recording a new combo in Settings updates the menu item; Esc cancels; bare letters beep (modifier required, F-keys exempt)
- [ ] "Use shortcut system-wide" mutes while another app is frontmost (Carbon hotkey; no accessibility prompt) and doesn't double-toggle when the app is frontmost
- [ ] Disabling the shortcut removes both the key equivalent and the global registration; settings persist across relaunch

## Known deviations from the desktop client (deliberate)

- The streaming TTS path sends raw deltas (the server strips markdown per sentence); the desktop does the same — the client-side sanitizer is applied on the whole-clip fallback path, matching `playSpeechText`.
- The fallback player stops + captures the stop-sequence *before* playback (the desktop captures after), so pressing Stop during a fallback clip reliably suppresses the mic re-arm.
- VAD levels are computed on fixed ~43 ms audio-callback hops instead of rAF ticks; normalization is scaled (÷ 42/128) so the desktop's thresholds apply unchanged.

## Not in v1

Text-chat UI beyond the dev screen, transcript history, wake-word detection, OAuth sign-in for gated remote backends (basic auth is supported; browser-redirect providers are not), editing profiles/config, voice-answered approvals.
