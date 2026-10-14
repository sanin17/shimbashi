# Shimbashi — Development Notes

An iOS app for practicing spoken Japanese with a live voice tutor.
Voice-first: you talk, the tutor replies in Japanese, and the screen shows Japanese / romaji / English.
Reading and writing are explicitly out of scope.

**Single provider: Gemini only.** Gemini Live (`gemini-3.1-flash-live-preview`) drives the realtime voice
conversation; `gemini-3.1-flash-lite` handles translation, phrase breakdown, and session summaries;
`gemini-3.1-flash-tts-preview` handles replay TTS. An earlier design split work between Gemini and Claude —
that was dropped early on and never came back. There is no `ClaudeClient` in this codebase.

---

## Architecture at a glance

```
RootView
  └─ ConversationListView       browse conversations, start a new one, Reset
       └─ ConversationView      one conversation, live (push-to-talk, single Start/Stop button)
                                · resuming == nil  → brand-new conversation
                                · resuming == past → picks that one back up
```

A conversation is finalized (connection torn down, summary + struggle notes generated) by **leaving the
screen or backgrounding the app** — there's no explicit end-session control, since a button for it was
redundant with simply navigating back. See `ConversationBody.endConversationIfActive`.

- **`Packages/VoiceCore/`** — local SPM package, Swift 6 strict concurrency. Owns the audio engine
  (one shared `AVAudioEngine`, voice processing on for echo cancellation) and the Gemini Live WebSocket
  transport. Surfaces as one `@MainActor @Observable VoiceSession` with `beginTurn()` / `endTurn()` /
  `endConversation()`.
- **`Shimbashi/`** — SwiftUI app target. Views, the translation/breakdown coordinator, SwiftData
  persistence, and the Gemini text/TTS clients.

**Interaction model is push-to-talk, not always-listening.** The connection stays open across a whole
visit, but the mic is only sent to the server between an explicit Start and Stop. Server-side voice
activity detection is disabled (`automaticActivityDetection.disabled: true`); each utterance is bracketed
with explicit `activityStart` / `activityEnd` frames. Tapping Start again mid-reply doubles as barge-in.

---

## Work completed

### Conversation model and navigation
- **Conversations are discrete, browsable, resumable threads.** Each conversation keeps its own preserved
  transcript. `ConversationListView` lists them (newest first, with date + AI summary); tapping one opens
  it live, so Start picks that conversation back up and new turns append to it. Starting a new one never
  erases the old ones.
- **"Resuming" is transcript continuity, not model memory.** Gemini Live has no cross-session recall, so a
  resumed conversation opens a fresh connection primed with *that* conversation's text recap (rather than
  the most recent one's) and reopens its `ConversationSession` row so turns append. The tutor reads as
  picking up the thread; it isn't literally remembering it.
- Earlier iterations tried a single merged "running ledger" across all sessions — replaced, because the
  actual need was separate browsable transcripts, not one continuous scrollback.

### Live conversation experience
- Push-to-talk redesign: one centered Start/Stop button, manual per utterance. Leaving the screen or
  backgrounding closes the conversation out and triggers summary + struggle-note extraction.
- Romaji/English update live while the tutor is still speaking, then get replaced by the authoritative
  translation once the turn finalizes.
- The phrase-by-phrase breakdown opens **automatically** in its own full-screen sheet when the tutor
  replies, at a large type scale. Any turn can also be tapped to reopen its breakdown.
- English input (e.g. "how do I say X?") is detected via `containsJapaneseScript` and skipped rather than
  run through the Japanese→English translator, which used to paraphrase it back as nonsense.

### Cost / API-call reductions
- **Translation + breakdown merged into one call** for tutor replies (`TranslationService.analyzeReply`).
  Since the breakdown now always opens automatically, both halves are always needed together.
- **Tutor reply audio is reused for playback.** Gemini Live already streams the spoken audio; it's now
  retained on `Turn.audio` and replayed directly (wrapped in a WAV header) instead of paying for a fresh
  TTS call. Per-phrase playback still synthesizes, since there's no per-phrase audio alignment.
- **TTS results are cached in-memory by text**, so replaying the same phrase costs nothing after the first.
- **Translations and breakdowns are persisted to SwiftData** once loaded, so reopening a past conversation
  never re-fetches them.
- **Network activity is visible in the UI**: a small blue cloud badge appears on any spinner or play button
  that is actually hitting Gemini. A plain spinner with no badge means local work only. This convention
  holds app-wide (`NetworkSpinner` + `PlayButton`).

### Bugs found and fixed
- **Transcript wiped on every new turn.** `ConversationCoordinator.sync()` rebuilt `displayTurns` from
  scratch from `session.turns` (which only ever holds the *current* connection's turns), so any seeded
  history vanished the instant a live turn arrived. Now additive — appends only unseen turns, never removes.
- **Crash when starting a second conversation.** Navigating back without tapping "End Session" left the
  previous `VoiceSession`'s `AVAudioEngine` fully running; a second engine then contended for the same
  shared `AVAudioSession`, corrupting the negotiated format to 0 Hz and crashing in `engine.connect(...)`.
  Fixed with an `.onDisappear` teardown, so the conversation ends whenever the screen leaves the stack.
- **Reconnect retried forever.** `GeminiLiveSession`'s retry budget was unreachable: `connect()` only
  throws on a JSON-encode failure, while real I/O failures surface later as a `receive()` failure, routing
  back through `beginReconnect()` → `attemptReconnect(attempt: 1)` every time. A persistently broken
  connection showed "Reconnecting…" forever instead of ever reporting failure. Fixed by making the attempt
  count persist across reconnect cycles, resetting only when a real event proves the connection healthy.
- **Stuck spinner under user turns.** `sync()` set `.notApplicable` through a lookup helper *before* the
  turn was committed to `displayTurns`, so the update was silently dropped. Now set directly on the value.
- **"Disconnected" after backgrounding.** An `AsyncStream.Continuation`, once `finish()`d, stays finished
  forever — `GeminiLiveSession.events` is now recreated fresh on every `start()`.
- **Phrase-mismatch false positive.** The breakdown sanity check flagged full-width `？` vs half-width `?`
  as content mismatch; comparison now normalizes width variants.

### Test coverage (102 tests)
- `Packages/VoiceCore/Tests/VoiceCoreTests/` — 59 tests: wire protocol encode/decode (`LiveInbound`,
  `LiveOutbound`, `LiveSetupFrame`), PCM/format math (`PCMFormats`, `PCMStreamResampler`), mic tap
  chunking (`MicTapContext`), and the transport actors (`GeminiLiveConnection`, `GeminiLiveSession`).
- `Shimbashi/ShimbashiTests/` — 43 tests: Japanese-script detection, WAV header layout, LLM JSON
  extraction (`TranslationService`, `StruggleExtractor`), the coordinator's routing/dedup/caching logic,
  and SwiftData persistence with an in-memory container — including regression tests for the
  transcript-wipe and dangling-session bugs above.
- Two small seams added purely for testability, with no behavior change: a `GeminiTextGenerating` protocol
  around `GeminiTextClient`, and an injectable `channelFactory` on `GeminiLiveSession`.

---

## Running things

```bash
# Build the app
xcodebuild -scheme Shimbashi -project Shimbashi.xcodeproj -destination 'generic/platform=iOS Simulator' build

# App tests
xcodebuild test -scheme Shimbashi -project Shimbashi.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ShimbashiTests

# VoiceCore tests — must run from Packages/VoiceCore/
cd Packages/VoiceCore && xcodebuild test -scheme VoiceCore -destination 'platform=iOS Simulator,name=iPhone 17'
```

The project is generated by **XcodeGen** — after adding any new source file, run `xcodegen generate` from
the repo root or the file won't be in the target.

---

## Traps worth remembering

These all cost real debugging time at least once.

**Build / tooling**
- `swift test` does **not** work for `VoiceCore` — the package is iOS-only, and bare `swift test` builds for
  the macOS host and fails on iOS-only APIs. Use `xcodebuild test` with a simulator destination, run from
  the package directory (running it from the repo root gives a misleading "Scheme not configured for the
  test action" error).
- `xcodegen generate` invalidates `xcodebuild`'s cached provisioning state, so CLI *device* builds start
  failing to sign. Xcode's GUI is unaffected — just hit Run there.
- Stale DerivedData can produce "Scheme VoiceCore is not currently configured for the test action."
  `rm -rf ~/Library/Developer/Xcode/DerivedData/VoiceCore-*` and retry.
- New test files nested under `Shimbashi/` must be excluded from the app target in `project.yml`, or they
  get compiled into the app (which doesn't link the Testing framework).

**Audio (`AVAudioEngine`) — most of these only reproduce on a real device**
- Never hardcode a playback format. Read what the engine actually negotiated (`outputFormat(forBus:)`);
  a mismatch produces silence with no error anywhere.
- Attach and connect the player graph **before** enabling voice processing. Doing it the other way round
  activates VoiceProcessingIO with no output bus and audio silently never reaches the speaker.
- Any closure handed to `installTap` must be explicitly `@Sendable`, or default MainActor isolation makes it
  crash the moment CoreAudio calls it from the realtime thread.
- Reuse one `AVAudioConverter` across a stream. A fresh one per chunk resets resampler state and clicks at
  every chunk boundary.
- Only ever one live `AVAudioEngine` at a time — they contend for the shared `AVAudioSession`.
- `AVAudioPlayerNode.scheduleBuffer` on a node never attached to an engine raises an uncaught exception and
  takes down the whole process. This is why `AudioPlaybackQueue` is largely untested.
- `AVAudioPlayerNode`'s `.dataPlayedBack` completion callback is unreliable — don't trust it as a diagnostic.

**Swift concurrency**
- An `AsyncStream.Continuation` that has been `finish()`d stays finished forever. Recreate the stream per
  logical session, not once at `init`.
- Cancelling a `Task` doesn't stop a `for await` loop until the underlying stream actually finishes — hence
  the generation counters guarding stale-task races.
- Mutating an `AsyncIterator` stored on an actor doesn't type-check cleanly under strict concurrency; a
  `CheckedContinuation` is the simpler path (see `FakeWebSocketChannel`).

**Gemini APIs**
- The TTS "Interactions API" response shape is `steps[].content[]` filtered on `type == "audio"` — *not*
  `output_audio.data` as the docs suggest. Note there is also an unrelated `"modality"` field elsewhere in
  the response; it is not the discriminator.
- TTS returns raw headerless PCM16, so it needs a manually built WAV header before `AVAudioPlayer` will
  touch it (`SpeechClient.wavData`).
- Gemini Live transcription arrives as incremental **deltas to append**, not cumulative snapshots.

---

## Not built / open

- **Scenario roleplay** (konbini, train ticket, ramen shop, etc.) — free-talk only today. Scenarios were
  designed as data (`scenarios.json`), never implemented.
- **Post-session debrief screen** — session summaries and struggle notes are generated and stored, and feed
  into the next session's system prompt, but there's no dedicated debrief UI.
- **Learner level / scaffolding ladder (L1–L3)** — designed, not implemented.
- **Persisted reply audio** — `Turn.audio` is in-memory only, so replaying the tutor's actual voice works
  within a session but not after relaunch (it falls back to TTS).
- **Untested by design**: `VoiceIOEngine` / `AudioSessionController` (need real hardware), most of
  `AudioPlaybackQueue` (see trap above), Keychain (a round-trip test would clobber the real stored API key),
  and the SwiftUI view layer (thin wiring, no branching logic).
- **Shipping**: the Gemini API key lives in the device Keychain, which is fine for personal use. Sharing
  this app would require a token-minting backend, and those tokens must lock `live_connect_constraints`.
