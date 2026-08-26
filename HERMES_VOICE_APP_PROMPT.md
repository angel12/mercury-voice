# Build "Hermes Voice" — a standalone macOS/iOS voice-conversation client for Hermes Agent

> **Historical document** — the original prompt this app was built from. The app has since been renamed **Mercury Voice** (issue #35); it is still a client for Hermes Agent.

## Mission

Build a native SwiftUI app (macOS + iOS, one multiplatform Xcode project) that is a **voice-only client for Hermes Agent** (https://github.com/NousResearch/hermes-agent). It replicates the desktop app's "voice conversation" feature as a standalone app:

- Connect to a running Hermes backend **exactly the way the desktop app does** (same server, same auth, same JSON-RPC WebSocket protocol — NOT the OpenAI-compatible `api_server` adapter).
- Let the user **pick the profile** the conversation runs under.
- Show **recent projects and sessions** so the user can either attach to an existing session or start a new session bound to a project's directory.
- Run a hands-free, full-duplex voice loop: listen → transcribe → submit → speak the streamed reply → re-arm the mic, with barge-in and spoken stop-words.

The hermes-agent reference source is the live checkout at `~/Coding/hermes agent` (mind the space when quoting paths; `git pull` it — or fetch `upstream` — to match the backend you're running; a fresh clone of https://github.com/NousResearch/hermes-agent works anywhere else). File references below are relative to that repo and were last verified against `main` as of 2026-08-13 (desktop contract v6); line numbers will have drifted, so search for the symbols named. **When in doubt about protocol behavior, read the referenced source — it is the contract.**

---

## Part 1 — How Hermes connectivity works (verified facts, use as the contract)

### 1.1 The server

The desktop app talks to one process: `hermes serve` (FastAPI/uvicorn, entry `hermes_cli/web_server.py`). The desktop spawns it as `hermes [-p <profile>] serve --host 127.0.0.1 --port 0` with env `HERMES_DASHBOARD_SESSION_TOKEN=<random base64url token>`, then reads the bound port from a stdout line matching `^HERMES_(BACKEND|DASHBOARD)_READY port=(\d+)` (`apps/desktop/electron/backend-command.ts:21`, `backend-ready.ts:6`, `web_server.py:17635`).

Two transports on that one server:

1. **WebSocket JSON-RPC 2.0** at `/api/ws` — the live agent channel (sessions, prompts, streaming events).
2. **HTTP REST** under `/api/*` — profiles, session lists, transcripts, config, and the audio (STT/TTS) endpoints.

### 1.2 Auth (token mode — implement first)

- REST: header `X-Hermes-Session-Token: <token>` (legacy `Authorization: Bearer <token>` also accepted). Verified in `_has_valid_session_token()` (`hermes_cli/web_server.py:398-415`).
- WebSocket: query param `?token=<token>`. Bad token → close code `4401`.
- `GET /api/health` and `GET /api/status` are public (no token). `/api/status` includes `auth_required: true` when the server is OAuth-gated — use it to classify the connection mode.
- The token lives only in process memory and **changes on every backend restart**. Ways the app can obtain it:
  - The user pastes the dashboard URL (hermes prints/opens `http://127.0.0.1:<port>/?token=...`) — parse the `token` query param. Best UX; support pasting either a full URL with token or base URL + separate token field.
  - Scrape `window.__HERMES_SESSION_TOKEN__` from `GET /` HTML (how Electron re-adopts it: `apps/desktop/electron/dashboard-token.ts:38-102`).
  - macOS-only stretch goal: spawn `hermes serve` ourselves with our own token, like the desktop.
- WS handshake rules (`web_server.py:14567-14641`): the `Host` header must match the bound host; `Origin` is optional and non-`http(s)` origins are allowed (native clients can simply omit it); when the server is bound to loopback and ungated, the **peer IP must be loopback** — so a phone cannot connect directly to a `127.0.0.1`-bound backend. See §4.4 for reachability recipes.

### 1.3 Auth (OAuth-gated remote mode — phase 2)

When the backend binds a non-loopback host it always requires auth (`should_require_auth`, `web_server.py:472-491`). REST then uses HttpOnly session cookies or an RFC 8252 native bearer token, and the WebSocket requires a **single-use ticket**: `POST /api/auth/ws-ticket` → connect with `?ticket=<t>` (30 s TTL, one dial per ticket, re-mint before every reconnect). Desktop implementation: `apps/desktop/electron/main.ts:6411-6443`, `apps/shared/src/websocket-url.ts:43-79`. Ship token mode first; add OAuth in a later milestone.

### 1.4 JSON-RPC wire protocol on `/api/ws`

Each WS text frame is one JSON-RPC 2.0 object.

```jsonc
// request (client → server); integer ids are fine (desktop uses them)
{"jsonrpc":"2.0","id":1,"method":"session.create","params":{...}}
// response
{"jsonrpc":"2.0","id":1,"result":{...}}
{"jsonrpc":"2.0","id":1,"error":{"code":4009,"message":"session busy"}}
// server-push event (no id)
{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"ab12cd34","payload":{"text":"..."}}}
```

- Immediately after accept, the server sends a `gateway.ready` event; no client hello is required (`tui_gateway/ws.py:314-326`).
- Only frames with `method == "event"` and `params.type` are events; everything else is a response.
- Error codes seen in practice: `4006` session_id required, `4007` session not found, `4009` session busy, `-32601` unknown method.
- Text deltas are coalesced server-side at ~30 fps; ordering with non-delta frames is preserved.
- **Two-ID model**: `session.create`/`session.resume` return a short **runtime** `session_id` (ephemeral, recycled on backend restart — all RPCs take this) and a durable `stored_session_id` (`YYYYMMDD_HHMMSS_<hex>` DB id — what session lists show). After any reconnect, re-`session.resume` by stored id; never trust cached runtime ids across reconnects.
- `session.info` events / `session.create.info` carry `desktop_contract` (currently `5`, `tui_gateway/server.py:4957-4965`) — read it for feature gating, and surface a warning if the backend is older than what the app was built against.

### 1.5 RPC methods the app needs

| Method | Params | Notes |
|---|---|---|
| `session.create` | `{cols: 96, source: "desktop", cwd?, profile?, title?}` | `cwd` binds the session to a project directory; omit for "no workspace". Returns `{session_id, stored_session_id, info:{cwd, project, profile_name, model, ...}}`. DB row is created lazily on first prompt. (`tui_gateway/methods_session.py:14-159`) |
| `session.resume` | `{session_id: <stored id>, cols: 96, source: "desktop", profile?, omit_messages: true}` | Attaches to an existing session; follows compression-continuation chains to the live tip; pass the session's owning profile. Hydrate transcript over REST instead of the socket. (`methods_session.py:306-722`) |
| `prompt.submit` | `{session_id, text, interrupted?: true}` | Returns `{"status":"streaming"}` immediately; completion arrives only via events. Set `interrupted: true` on the first submit after a barge-in — the backend prepends a note telling the model its spoken reply was cut off. Use a very long request timeout (desktop: 30 min). |
| `session.interrupt` | `{session_id}` | Cancel the in-flight turn (used on barge-in while the agent is still generating). |
| `session.list` | `{limit, offset}` | Session browser over RPC (REST alternative below). |
| `projects.list` | `{}` | → `{projects, active_id}` from the profile's `projects.db`. |
| `projects.tree` | `{preview_limit: 3}` | → `{projects, active_id, scoped_session_ids}` — the authoritative sidebar grouping (explicit projects, auto repo projects, `__no_project__` Home bucket) with per-project preview sessions. (`tui_gateway/project_tree.py`, `methods_config.py:108`) |
| `projects.project_sessions` | `{project_id}` | Sessions belonging to one project (drill-in). |
| `session.close` | `{session_id}` | Detach politely when leaving. |
| `approval.respond` / `clarify.respond` | `{session_id, ...}` | Answers to `approval.request` / `clarify.request` events (see §3.6). Read the handler signatures in `tui_gateway/` for exact fields before implementing. |

### 1.6 Events the app must consume

`message.start`, `message.delta {text}`, `message.interim`, `message.complete {text, status: "complete"|"error", error?}`, `thinking.delta`, `tool.start {name}`, `tool.complete`, `status.update {kind, text}`, `approval.request`, `clarify.request`, `session.info`, `session.title`, `notification.show`, `error`.

Turn-busy bookkeeping (mirrors the desktop): mark the session **busy** at `message.start` (or on submit) and **not busy** at `message.complete`/error. The voice loop needs this signal (§3.4).

### 1.7 REST endpoints the app needs

All with `X-Hermes-Session-Token` header. Endpoints that resolve provider config accept `?profile=<name>` — **always pass the conversation's profile** on the audio endpoints.

| Endpoint | Purpose |
|---|---|
| `GET /api/health`, `GET /api/status` | Liveness + auth-mode probe (public). |
| `GET /api/profiles` | `{profiles: [{name, path, is_default, model, provider, skill_count, has_env}]}` — can take tens of seconds (walks skill trees); use a 60 s timeout like the desktop. |
| `GET /api/profiles/active` | `{active, current}`. |
| `GET /api/sessions?limit&offset&min_messages` | Recent sessions of the *serving* profile. |
| `GET /api/profiles/sessions?profile=<all\|name>&limit=...` | Cross-profile session list; rows tagged with owning `profile`. Rows include `cwd`, `git_repo_root`, `git_branch`, `title`, `pinned`, `profile`. |
| `GET /api/sessions/{stored_id}/messages?profile=` | Transcript hydration (only needed if you display history). |
| `POST /api/audio/transcribe?profile=` | Body `{data_url: "data:audio/...;base64,...", mime_type}`. → `{ok, transcript, provider}`. **Empty transcript = silence, not an error** — quietly re-listen. ≤25 MiB. Accepted mimes include `audio/wav`, `audio/m4a`, `audio/x-m4a`, `audio/mp4`, `audio/aac` (`web_server.py:1400-1414`) — record WAV 16 kHz mono PCM or M4A/AAC from AVAudioEngine. |
| `POST /api/audio/speak?profile=` | Body `{text}` → `{ok, data_url, mime_type}` — whole-clip TTS **fallback** path. |
| `GET /api/audio/elevenlabs/voices` | Only if you build voice-picker settings (optional). |

### 1.8 Streaming TTS WebSocket — `/api/audio/speak-stream?token=...&profile=<name>`

The primary speech path (`web_server.py:4615-4763`, client reference `apps/desktop/src/lib/voice-playback.ts`). One socket per spoken reply:

```
client → {"text": "<delta>"}   // incremental, as message.delta events arrive
client → {"done": true}        // when the reply is complete
client → {"stop": true} or close  // barge-in: server aborts synthesis
server → {"type":"start","sample_rate":24000,"channels":1}
server → <binary frames: raw int16 little-endian mono PCM>
server → {"type":"end"}
server → {"type":"fallback"}   // configured TTS provider has no chunked API
                               // → use POST /api/audio/speak with the full text instead
```

Playback: feed the PCM into `AVAudioPlayerNode`/`AVAudioEngine` gap-free (convert int16 → float32, build `AVAudioPCMBuffer`s at the advertised sample rate, schedule back-to-back; carry an odd trailing byte across frames). After `end`, wait for the scheduled tail to drain before declaring speech finished. Server-side sentence-chunking handles pacing — just forward text deltas promptly (desktop feeds on a 150 ms timer).

---

## Part 2 — Product spec

Four screens/flows. Keep the UI minimal and polished — this is a voice appliance, not a chat app.

### 2.1 Connect screen
- Fields: server URL (accepts `host`, `host:port`, full `http(s)://` URL, or a pasted dashboard URL with `?token=`) + token field (auto-filled if the pasted URL had one).
- Probe `/api/status` → show server version/auth mode; validate the token with any cheap authed GET; then open `/api/ws` and wait for `gateway.ready`.
- Persist per-server credentials in **Keychain**. Remember multiple servers; auto-reconnect to the last one on launch.
- Reconnect machinery: full-jitter exponential backoff (`delay = random() * min(15s, 300ms * 2^attempt)`), immediate re-dial on app-foreground/network-change, and after every reconnect re-resume the active session by **stored** id (runtime ids are recycled).

### 2.2 Profile picker
- `GET /api/profiles`; show name, model, provider, skill count; mark the default/active one. Selection = the profile new conversations run under (passed as `profile` on `session.create`/`session.resume` and `?profile=` on all audio calls).
- Note: a profile is a whole isolated `HERMES_HOME` (own config, own sessions DB, own projects DB) — so switching profile must refresh the projects/sessions lists too.

### 2.3 Project & session picker
- Data: `projects.tree {preview_limit: 3}` for the grouped view (explicit projects, auto repo projects, "Home" bucket with id `__no_project__`), plus `GET /api/profiles/sessions?profile=<selected>` for a flat Recents list (exclude ids in `scoped_session_ids`).
- Each project row: name, primary path, up to 3 recent sessions (title + relative time).
- Actions:
  - **New conversation in project** → `session.create {cwd: <project primary_path>, profile}`.
  - **New conversation, no workspace** → `session.create` without `cwd`.
  - **Continue session** → `session.resume {session_id: <stored_id>, profile: <row's owning profile>, omit_messages: true}`.
- If `projects.*` RPCs are unavailable (older backend), degrade to grouping the flat session list by `git_repo_root` ?? `cwd`.

### 2.4 Voice conversation screen
The heart of the app. Full-screen, glanceable state:
- Big status orb + label for the five states: **idle / listening / transcribing / thinking / speaking** (see §3.1), with live mic level while listening and output waveform while speaking.
- Rolling caption area: the last transcript the user spoke and the assistant's reply text as it streams (voice-first, but captions make it usable and debuggable). Show tool activity as a one-line ticker ("Running: Bash…") from `tool.start` events.
- Controls: mute toggle, "tap to end turn now" (force-transcribe, equivalent of the desktop's Space bar), Stop (end speech + do not re-arm), End conversation. Session title + profile + project shown in the header.
- Approval/clarify requests surface as a modal sheet with the choices as buttons (§3.6) — pause the voice loop while one is pending, and speak a short notice ("Hermes is asking for approval to run a command").

---

## Part 3 — Voice pipeline spec (mirror the desktop's state machine)

Reference implementation to mirror: `apps/desktop/src/app/chat/composer/hooks/use-voice-conversation.ts` (state machine), `use-mic-recorder.ts` (capture + VAD), `lib/voice-barge-in.ts` (interrupt monitor), `lib/voice-playback.ts` (TTS transport), `lib/voice-stop-word.ts`, `lib/speech-text.ts` (sanitizer).

### 3.1 States and transitions

`idle → listening → transcribing → thinking → speaking → (re-arm) listening`

| From | Trigger | To |
|---|---|---|
| listening | VAD: heard speech, then **1250 ms** trailing silence | transcribing |
| listening | never heard speech for **12 s** | re-listen (fresh turn) |
| listening | **60 s** hard turn cap | transcribing |
| listening | user taps "end turn" | transcribing (force) |
| transcribing | empty transcript / STT error | listening (quietly re-arm) |
| transcribing | transcript is a stop command | conversation ends |
| transcribing | real transcript → `prompt.submit` | thinking |
| thinking | first assistant text arrives | speaking (open speak-stream, feed deltas) |
| thinking | turn completes with no speakable text (tool-only/error) | listening |
| speaking | stream `end` + playback drained (turn complete) | listening |
| speaking/thinking | barge-in trip | capture utterance → transcribe → submit with `interrupted: true` |
| any | Stop button | idle, **no re-arm** |
| any | End conversation | teardown |

Re-arm rule: after speech finishes, re-open the mic **unless** the user explicitly pressed Stop.

### 3.2 Capture + VAD (listening phase)

- `AVAudioEngine` input tap, mono. Compute RMS per ~50 ms hop, normalized to 0…1 (the desktop normalizes so conversational speech ≈ 0.1–0.4; calibrate your normalization so the same thresholds work: it uses `min(1, rms/42)` over 8-bit-centered samples — with float samples, `min(1, rms * 3.05)` is the equivalent starting point; verify empirically).
- Thresholds (desktop hardcodes these; do the same, expose in a debug panel): speech level ≥ **0.075**; end-of-turn silence **1250 ms**; idle give-up **12 000 ms**; hard cap **60 s**; max recording 120 s.
- Encode the utterance as **WAV 16 kHz mono int16** (or M4A/AAC) → base64 data URL → `POST /api/audio/transcribe?profile=`. Enable iOS voice-processing (`setVoiceProcessingEnabled(true)` on the input node or `.voiceChat` audio session mode) for echo cancellation + noise suppression.

### 3.3 Speaking phase

1. On the first `message.delta` of the turn, open `/api/audio/speak-stream?token&profile`, send accumulated **sanitized** text, then keep feeding new deltas (~150 ms cadence).
2. Sanitize before sending (mirror `speech-text.ts`): strip fenced code (→ "code block omitted"), markdown tables, headings/list markers, inline code/link markup, URLs (→ "link"), emoji, `<think>` blocks.
3. Speak **all** assistant bubbles of the turn (interim narration + final answer), concatenated in order; track a "last spoken message id" so nothing is voiced twice.
4. Send `{"done": true}` only when the turn is finished: **no pending delta stream AND turn not busy** (`message.complete` seen).
5. On `{"type":"fallback"}` or WS error before any audio: fall back to `POST /api/audio/speak` with the full sanitized reply text, play the returned data URL with `AVAudioPlayer`.
6. Stop = close the socket (server aborts) + stop the player nodes immediately.

### 3.4 Barge-in (full duplex)

Run a monitor on the mic during **thinking and speaking** (`voice-barge-in.ts` constants):
- Calibrate a quiet noise floor for 400 ms (median of quiet samples, keep ≤200 samples, only update while output is quiet — echo cancellation is not trusted).
- Trigger level = `max(floor × 3.5, 0.075)`, and while TTS is audibly playing clamp to `[0.14, 0.37]`.
- Trip when ≥80 % of a 300 ms window exceeds the trigger; ignore the first 500 ms after playback starts (onset transient).
- On trip: stop playback immediately; if the turn is still generating, send `session.interrupt`; keep recording until 1250 ms of silence (30 s cap), **retaining pre-roll** so the first syllable survives (rotate a short ring buffer while quiet).
- Transcribe the captured utterance: empty → resume listening; stop-word → end conversation; else wait until the interrupted turn settles (poll busy, ≤5 s) then `prompt.submit {text, interrupted: true}`.

### 3.5 Stop words

Full-utterance match only, after normalizing (lowercase, strip `.,!?;:…`, collapse spaces) and stripping address prefixes (`hey hermes`, `hermes`, `okay`, `ok`, `hey`): `stop`, `stop listening`, `stop it`, `stop please`, `please stop`, `stop stop`, `that is all`, `that's all`, `never mind`, `nevermind`, `end conversation`, `end the conversation`, `goodbye`, `good bye`, `bye`, `cancel`. "Stop the docker container" must pass through as a prompt (`voice-stop-word.ts`).

### 3.6 Approvals and clarifications

Agent turns can emit `approval.request` (command + choices like once/session/always/deny) and `clarify.request`. A voice-only app **must** handle these or turns will hang: pause the loop, present a sheet with the payload's choices, reply via `approval.respond`/`clarify.respond`, resume. Speaking the request text aloud is a nice touch; voice-answering approvals is out of scope for v1.

---

## Part 4 — Apple platform integration

- **Targets**: SwiftUI, iOS 17+ / macOS 14+, Swift 5.10+ with strict concurrency. One multiplatform app target; share everything except small platform shims.
- **Audio session (iOS)**: `AVAudioSession` category `.playAndRecord`, mode `.voiceChat`, options `[.defaultToSpeaker, .allowBluetoothA2DP]`. Handle interruptions (calls) and route changes (AirPods) by pausing/resuming the loop cleanly.
- **Background**: enable the `audio` background mode on iOS so a conversation survives screen lock while actively listening/speaking.
- **Permissions**: `NSMicrophoneUsageDescription` (both platforms); iOS **local network** usage description + Bonjour-less local networking prompt will appear on first LAN dial; macOS App Sandbox needs `com.apple.security.network.client` + microphone entitlement.
- **ATS**: local Hermes servers are plain `http://`/`ws://`. Add `NSAppTransportSecurity → NSAllowsLocalNetworking` (and `NSAllowsArbitraryLoads` only if a non-local plain-HTTP host must be supported — prefer requiring https or Tailscale for remote).
- **Networking**: `URLSession` for REST; `URLSessionWebSocketTask` for both WebSockets (add a ping-less keepalive expectation: the server disables WS pings on loopback binds; long agent turns can stall frames for minutes — do not treat quiet as dead while a turn is busy).
- **Keychain** for tokens (per-server), `@AppStorage`/`UserDefaults` for non-secret prefs.
- **Reachability recipes to document in-app help**: same-Mac (localhost, token mode); iPhone → Mac on LAN/Tailscale requires either an OAuth-gated non-loopback bind, `tailscale serve` (proxies from loopback on the host, so token mode works), or an SSH tunnel from another Mac.

## Part 5 — Architecture

Three modules (Swift packages or groups):
1. **HermesKit** — connection config, token store, REST client, `JSONRPCGatewayClient` (request/response correlation, event demux, reconnect with backoff), typed models (`ProfileInfo`, `SessionInfo`, `ProjectInfo`, gateway events), session/project services. No UI, fully unit-testable.
2. **VoiceEngine** — mic capture + VAD, barge-in monitor, utterance recorder/encoder, STT client, speak-stream client + PCM scheduler, fallback player, stop-word matcher, text sanitizer, and the conversation state machine as a testable `actor` that consumes protocol events and emits UI state.
3. **App/UI** — the four screens, driven by observable state from the two modules.

The state machine must be **pure enough to unit test**: inject clock, audio levels, transcription results, and gateway events; assert transitions (the desktop has tests worth porting conceptually: `use-voice-conversation.test.tsx`, `use-voice-conversation-rearm.test.tsx`, `voice-stop-word.test.ts`).

## Part 6 — Milestones (each ends runnable + demoable)

1. **Connect + browse**: connect screen, token auth, `gateway.ready`, profile list, project tree + recent sessions rendering. Verify against a live local `hermes serve`.
2. **Text-path conversation (hidden dev screen)**: `session.create`/`resume`, `prompt.submit`, streamed reply rendering, busy tracking, approval sheet. This proves the RPC layer before audio exists.
3. **Voice out**: speak-stream PCM playback of replies + `/api/audio/speak` fallback + sanitizer.
4. **Voice in**: capture, VAD, transcribe, submit; the full loop with re-arm; stop words; mute.
5. **Barge-in + interrupted flag + polish**: monitor, `session.interrupt`, pre-roll capture; reconnect/resume hardening; background audio; both platforms tested end-to-end.
6. *(Stretch)* OAuth ticket mode for gated remote gateways; macOS auto-spawn of `hermes serve`.

## Part 7 — Verification

- Stand up a real backend: `pip install`/`uv sync` the hermes-agent repo (or use an existing install), run `hermes serve --host 127.0.0.1 --port 0` with `HERMES_DASHBOARD_SESSION_TOKEN` set, note the `HERMES_..._READY port=` line. A minimal reference WS client lives at `scripts/iso-certify.py` in the hermes-agent checkout (`WSClient` + `drive_heavy_turn`) — mirror its handshake in an early integration test.
- STT/TTS require providers configured in the profile's `~/.hermes/config.yaml` (`stt.*`, `tts.*`; defaults: local faster-whisper STT, edge TTS which is **non-streaming** → exercises the fallback path; a streaming provider like openai/elevenlabs exercises speak-stream).
- Test matrix: silence-only turn (empty transcript → re-listen), stop word, barge-in during speech, barge-in during generation, approval mid-turn, backend restart mid-conversation (reconnect + resume by stored id), profile switch, new-session-in-project cwd correctness (check `session.info.cwd`/`project`), fallback TTS provider.

## Non-goals (v1)

Text chat UI, message history browsing beyond recents, wake-word ("hey hermes") detection, editing profiles/config, kanban/cron/plugins surfaces, the OpenAI-compatible `api_server` adapter, voice-answered approvals, Android/web.

## Known sharp edges (learned from the source — don't rediscover these)

- `prompt.submit` returns immediately; **never** await it for the reply. Completion is `message.complete` only.
- Empty transcript is success, not an error (`web_server.py:4383-4387`). Re-listen silently.
- `GET /api/profiles` is slow (walks skill trees) — 60 s timeout, cache the result.
- Runtime session ids are recycled after backend restarts — always re-resume by `stored_session_id` and re-bind.
- A session's owning profile matters: resuming another profile's session requires passing that `profile` to `session.resume` (cross-profile resume opens that profile's `state.db`).
- The speak-stream socket ends a *reply*, not the app's turn logic — finish (`done`) only when delta stream ended AND busy cleared, or trailing narration gets cut off.
- Server WS pings are disabled on loopback binds; a multi-minute quiet socket during a busy turn is healthy.
- Frame size: `file.attach` raises `ws_max_size` to 384 MiB server-side; your client only needs modest frames but must tolerate large inbound `session.info`/transcript frames.
