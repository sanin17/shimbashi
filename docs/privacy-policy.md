# Shimbashi Privacy Policy

*Effective October 26, 2026 — Sanin Codes, LLC*

Shimbashi is a Japanese-speaking practice app. This page explains, in plain language, what happens
to your data.

## The short version

- Shimbashi has **no accounts and no servers of its own**. We never receive your voice, your
  conversations, or your API key.
- Your voice and your conversation text go **straight from your phone to Google's Gemini service**,
  using the API key you provide.
- Everything else stays **on your phone**, and you can delete it.
- No advertising, no analytics, no tracking.

## What gets sent, and to whom

Shimbashi uses Google's Gemini API through your own API key. While you use the app, it sends Google:

- **Your voice** — only while a turn is open, between tapping Start and tapping Stop. The microphone is
  not used at any other time.
- **Text of the conversation** — what you and the tutor said, so Gemini can translate it, break it into
  phrases, summarize it, and note what you found difficult.
- **Short phrases** — when you tap a speaker icon, that phrase is sent to be turned into speech.

This traffic is encrypted (HTTPS) and goes to Google, not to us. Google handles it under its own terms
and privacy policy for the Gemini API:

- <https://ai.google.dev/gemini-api/terms>
- <https://policies.google.com/privacy>

Please note that those terms depend on the type of key you use. On Google's **free tier**, Google may
use the content you send to improve its products, which can include review by people. A billed key is
treated differently. In some regions Google requires a billed account. Check Google's terms for your
situation, and avoid speaking anything you wouldn't want Google to process under the free tier.

## What stays on your phone

- **Your API key**, in the iOS Keychain, set to *this device only* (it isn't backed up or synced to
  other devices). It is only ever sent to Google, to authenticate your requests.
- **Your conversation history** — transcripts, translations, summaries, and notes about what you've
  struggled with — in the app's private storage.
- **Settings** such as whether you've seen the welcome walkthrough.

We don't have access to any of it.

## Your choices and deleting your data

- **Delete conversation history:** Conversations screen → the trash button → *Reset Everything*.
- **Remove your API key:** Settings → Gemini API Key → *Remove Key*. Do this before deleting the app —
  iOS can keep Keychain items after an app is removed.
- **Revoke access at Google:** delete or restrict the key in Google AI Studio at any time.
- **Microphone:** you can turn access off in iOS Settings → Shimbashi. The app then can't hear you, but
  everything else still works.
- Deleting the app removes the conversation history it stored.

## Children

Shimbashi isn't directed at children under 13, and we don't knowingly collect anything from them
(we don't collect anything at all).

## Changes

If this policy changes, the updated version will be posted here with a new effective date.

## Contact

Questions about this policy: open an issue at <https://github.com/sanin17/shimbashi/issues>.
