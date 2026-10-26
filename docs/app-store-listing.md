# App Store listing — copy to paste into App Store Connect

## App information

| Field | Value |
|---|---|
| Name | Shimbashi |
| Subtitle (max 30) | Speak Japanese out loud |
| Primary category | Education |
| Primary language | English (U.S.) |
| Price | Free |
| Support URL | https://github.com/sanin17/shimbashi/issues |
| Privacy Policy URL | *(the hosted copy of `docs/privacy-policy.md` — see "Hosting" below)* |
| Copyright | 2026 Sanin Codes, LLC |

## Promotional text (max 170)

Practice real spoken Japanese with a live voice tutor. Talk, listen, then tap any reply to study it phrase by phrase, with romaji and English.

## Keywords (max 100, comma-separated)

japanese,speaking,conversation,tutor,voice,practice,romaji,pronunciation,listening,language,learn,ai

## Description

Shimbashi is a live voice partner for practicing spoken Japanese.

Tap Start, say something in English or Japanese, and tap Stop. Your tutor answers out loud in Japanese, and the screen shows the Japanese, the romaji, and the English so you can follow along.

HOW IT HELPS
• Real conversation — talk about anything, at your own pace
• Tap any reply to break it into phrases, each with its romaji and meaning
• Replay any phrase to hear it again
• Your tutor remembers the thread of the conversation, and what you found tricky
• Pick up a past conversation where you left off
• Speaking and listening only — no flashcards, no typing

BRING YOUR OWN KEY
Shimbashi connects to Google's Gemini using your own API key. A key is free to create at Google AI Studio and takes about two minutes; the app walks you through it. That means there's no account to make and no subscription to buy.

PRIVATE BY DESIGN
• No account, no ads, no tracking, no analytics
• Your voice and conversation text go straight from your phone to Google, using your key — never to us
• Your key stays in your phone's Keychain
• Conversation history is stored only on your device, and you can delete it anytime

Note: Google's terms for the Gemini API apply to the content you send. On Google's free tier, Google may use it to improve its products.

## What's New (version 1.0)

First release.

## App Store Connect questionnaires

**Age rating.** Answer the questionnaire honestly: the tutor is an AI chat feature that responds to
spoken input, it has no web access, and the app has no user-to-user features, gambling, or mature
content. Let App Store Connect compute the rating from those answers.

**App Privacy ("nutrition label").** The developer receives nothing, but data is sent to Google, a
third party, for the app to work, so declare it:

| Data type | Collected | Linked to identity | Used for tracking | Purpose |
|---|---|---|---|---|
| Audio Data (under User Content) | Yes | No | No | App Functionality |
| Other User Content (conversation text) | Yes | No | No | App Functionality |
| Everything else (contacts, location, identifiers, usage, diagnostics, …) | No | — | — | — |

"Data Used to Track You": none. This matches the app's `PrivacyInfo.xcprivacy`.

**Export compliance.** The app uses only standard HTTPS (`ITSAppUsesNonExemptEncryption` is `false`),
so no export documentation is required.

**Advertising identifier (IDFA).** Not used.

## Screenshots

Required: iPhone 6.9" (1320×2868) or 6.5" (1284×2778 / 1242×2688). The app is iPhone-only, so no iPad
screenshots are needed. Suggested set, in order:

1. The welcome walkthrough ("Speak Japanese out loud")
2. A conversation in progress, with a tutor reply showing Japanese, romaji, and English
3. The phrase breakdown screen
4. The Conversations list with a couple of past conversations
5. The "Bring your own Gemini key" screen

Capture them on a device or simulator, and don't include a real API key in any screenshot.

## Hosting the privacy policy

App Store Connect needs a public URL. Easiest: in the GitHub repository, **Settings → Pages**, set the
source to the `main` branch and the `/docs` folder; the policy is then served at
`https://sanin17.github.io/shimbashi/privacy-policy`. Any other public page with the same text works.
