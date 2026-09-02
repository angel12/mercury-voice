# Mercury Voice Support

Mercury Voice is a voice client for [Hermes Agent](https://github.com/NousResearch/hermes-agent),
an open-source coding agent that runs on your own computer. The app does not
include or host the agent. You need a running Hermes server to use it.

## Getting connected

1. Start your Hermes server. For use over the internet or a VPN, bind it behind
   TLS and configure a password (`dashboard.basic_auth`) or OAuth gate.
2. In Mercury Voice, enter the server address. You can paste the dashboard URL
   hermes prints at startup (the token is picked up automatically), an
   address like `192.168.1.5:9119`, or a DNS name.
3. Tap **Connect**. If the server has a password gate, a sign-in form appears.
4. Pick a project and tap the microphone.

## Common problems

**"Couldn't reach the server."** Check that the address and port are right and
that your phone can reach the machine (same Wi-Fi, VPN, or a public DNS name
with TLS). Plain HTTP works for IP addresses and `.local` names; DNS names
default to HTTPS.

**No spoken reply.** The server needs a text-to-speech provider configured. The
free `edge` provider works out of the box.

**Nothing is transcribed.** The server needs a speech-to-text provider with a
valid key.

**Microphone permission denied.** Open Settings → Privacy & Security →
Microphone and enable Mercury Voice.

**Conversation stops when the screen locks.** Make sure Background App Refresh
and audio are allowed for the app, and that Low Power Mode is off.

## Reporting a bug or asking a question

Open an issue: https://github.com/angel12/mercury-voice/issues

Include your iOS or macOS version, the Hermes version, and what you expected
to happen.

## Privacy

See the [Privacy Policy](privacy-policy.md). The app collects nothing and has
no backend of its own.
