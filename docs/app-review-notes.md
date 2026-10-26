# App Review Notes (paste into App Store Connect → App Review Information → Notes)

Shimbashi is a spoken-Japanese practice app. There is no sign-in or account.

**The app uses the user's own Google Gemini API key** (bring-your-own-key). It has no backend; it talks
directly to Google's Gemini API from the device. A key is free to create and needs no billing or
credit card for the light use a review involves.

## How to get a key (about two minutes)

1. Go to https://aistudio.google.com/apikey and sign in with any Google account.
2. Tap **Create API key** and choose (or create) a project.
3. Copy the key.
4. In Shimbashi, tap **Add API Key** (on the home screen, or Settings → Gemini API Key), paste it, and
   tap **Save**. The app checks the key with Google before saving it and shows a clear message if
   Google rejects it.

## What to try

1. Home → **Conversations** → **New Conversation**.
2. Tap **Start**, say something in English or Japanese (for example "How do I order coffee?"), then tap
   **Stop**. Allow microphone access when iOS asks.
3. The tutor replies out loud in Japanese. The reply appears with its romaji and English translation.
4. Tap the reply to open a phrase-by-phrase breakdown; tap a speaker icon to hear a phrase.
5. Settings → **How Shimbashi Works** replays the first-run walkthrough.

## Permissions and data

- **Microphone**, used only between tapping Start and Stop. The app ends a conversation whenever it
  leaves the foreground, and declares no background modes.
- Voice and conversation text are sent only to Google's Gemini API using the user's key. The developer
  receives nothing. No analytics, ads, or tracking. Conversation history is stored on the device and
  can be deleted from the Conversations screen.
- Privacy policy and support are linked in the App Store listing.

## Notes

- Google's free tier occasionally answers "high demand". The app retries automatically and falls back to
  a second model; if a reply still fails it shows a tap-to-retry control.
- If you can't create a key for any reason, please tell us in the Resolution Center and we'll respond
  right away.
