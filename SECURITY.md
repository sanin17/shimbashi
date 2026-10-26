# Security

## Reporting a vulnerability

Please report security problems privately, not in a public issue. Use GitHub's
**Security → Report a vulnerability** on this repository. Include what you found, how to reproduce it,
and which version you tested. You'll get an acknowledgement, and a fix or an explanation as soon as
practical.

## What matters most here

Shimbashi holds one secret — the user's own Gemini API key — and sends microphone audio to Google.
Reports about any of these are especially welcome:

- The key being stored, logged, displayed, or transmitted anywhere other than the iOS Keychain and
  Google's API (over HTTPS, in a header)
- Audio being captured or sent outside a Start/Stop turn
- Conversation history leaving the device

## Secrets in this repository

No keys, tokens, certificates, or credentials belong in this repository, and none are committed. The
app has no server, so there is nothing to configure. If you ever spot one, please report it as above.
