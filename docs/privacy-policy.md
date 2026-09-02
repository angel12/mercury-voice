# Mercury Voice Privacy Policy

_Last updated: 2026-09-02_

Mercury Voice is a voice client for a Hermes Agent server that **you** run. The
app is made by Spencer McGuire ("we"). This policy explains what the app does
with your data. The short version: **the app has no backend of its own and
collects nothing.**

## What we collect

Nothing. Mercury Voice has no developer-operated server, no analytics, no
crash reporting, no advertising, and no third-party SDKs. We never see your
audio, your transcripts, your server address, or your credentials.

## What stays on your device

- **Server addresses and preferences** (theme, audio device, silence timing,
  cue sounds) are stored in the app's local preferences.
- **Session tokens and passwords** for each server you add are stored in the
  device Keychain, marked as device-only so they are never synced to iCloud
  Keychain or restored onto another device.
- **Speech-provider API keys** that your server hands the app for client-direct
  voice mode are held in memory only. They are never written to disk or
  logged.

## Where your data goes

Mercury Voice sends data only to servers you configure:

1. **Your Hermes Agent server.** Microphone audio (or its transcript), the text
   you type, and control messages are sent to the server address you entered.
   The server is operated by you or someone you chose; we do not operate it.
2. **Speech providers your server configures.** In client-direct voice mode,
   the app sends microphone audio directly to the speech-to-text provider and
   receives audio from the text-to-speech provider that **your server** is
   configured to use, with **your server's** API keys. Depending on your
   server's configuration this may be OpenAI (or an OpenAI-compatible service
   such as Groq, Mistral, or DeepInfra), xAI, or ElevenLabs. Their handling of
   that audio is governed by their own policies:
   - OpenAI: https://openai.com/policies/privacy-policy
   - xAI: https://x.ai/legal/privacy-policy
   - ElevenLabs: https://elevenlabs.io/privacy-policy
   - Groq: https://groq.com/privacy-policy · Mistral: https://mistral.ai/terms#privacy-policy · DeepInfra: https://deepinfra.com/privacy

Nothing is sent anywhere else.

## Microphone

The app uses the microphone only while a conversation is active or while you
have it armed to listen. Audio is streamed to the destinations above and is not
retained by the app. You can revoke microphone access at any time in system
Settings; the app will show a message and stop listening.

## Local network

On iOS the app may ask for local-network permission. It is used solely to
reach a Hermes server on your own network. The app does not scan or catalog
devices.

## Retention and deletion

- Uninstalling the app removes all local preferences.
- Removing a saved server (the trash button on the connect screen) deletes that server's Keychain entry.
- Conversation history lives on your Hermes server, under its retention rules,
  not in the app.

## Children

Mercury Voice is not directed at children under 13 and relays output from an
AI agent you configure.

## Changes

We will update this page and the date above when this policy changes. The
current version is always available at the URL listed in the app's Settings.

## Contact

Open an issue at https://github.com/angel12/mercury-voice/issues or email the
address listed on the App Store product page.
