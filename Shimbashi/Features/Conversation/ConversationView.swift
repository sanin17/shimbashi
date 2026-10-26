import SwiftUI
import SwiftData
import VoiceCore

/// One conversation, live. Reached from `ConversationListView` either as a
/// brand-new conversation (`resuming == nil`, empty transcript) or by
/// tapping a past one to pick it back up (`resuming` set — its transcript is
/// seeded on screen, new turns append to it, and the tutor is primed with
/// *that* conversation's recap).
///
/// "Resuming" is transcript continuity, not model memory: Gemini Live has no
/// cross-session recall, so an older conversation is continued by injecting
/// its recap into a fresh connection's system prompt — the same mechanism a
/// new conversation uses to reference the last one.
struct ConversationView: View {
    /// The past conversation to pick back up, or `nil` to start a new one.
    var resuming: ConversationSession?

    @Environment(\.modelContext) private var modelContext
    @State private var session: VoiceSession?
    @State private var coordinator: ConversationCoordinator?
    @State private var store: ConversationStore?
    @State private var geminiTextClient: GeminiTextClient?
    @State private var speechPlayback: SpeechPlaybackController?
    @State private var showingKeySetup = false
    /// No key saved yet — shows an inline prompt instead of an empty spinner.
    @State private var needsKey = false
    /// The key sheet opens on its own the first time only; after that a
    /// dismissed sheet leaves the inline prompt, rather than re-presenting
    /// itself in a loop the learner can't get out of.
    @State private var didPromptForKey = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let session, let coordinator, let store, let speechPlayback {
                ConversationBody(
                    session: session,
                    coordinator: coordinator,
                    store: store,
                    geminiTextClient: geminiTextClient,
                    speechPlayback: speechPlayback,
                    resuming: resuming,
                    onFixKey: { showingKeySetup = true }
                )
            } else if needsKey {
                MissingKeyView(onAdd: { showingKeySetup = true })
            } else {
                ProgressView("Starting…")
            }
        }
        .brandScreen()
        .navigationTitle(resuming?.displayLabel ?? "Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingKeySetup, onDismiss: startIfPossible) {
            // A new key means a fresh connection: the existing session (if
            // any) was built with the old one.
            APIKeySetupView(onSave: restartWithNewKey)
        }
        .task {
            startIfPossible()
        }
        .alert("Error", isPresented: .constant(errorMessage != nil), actions: {
            Button("OK") { errorMessage = nil }
        }, message: {
            Text(errorMessage ?? "")
        })
    }

    /// Drops the current session and builds a new one with whatever key is
    /// in the Keychain now. Removing the old body also runs its teardown
    /// (`onDisappear`), which closes the old connection and conversation.
    private func restartWithNewKey() {
        session = nil
        coordinator = nil
        store = nil
        geminiTextClient = nil
        speechPlayback = nil
        startIfPossible()
    }

    private func startIfPossible() {
        guard session == nil else { return }
        guard let geminiKey = Keychain.load(.geminiAPIKey), !geminiKey.isEmpty else {
            needsKey = true
            if !didPromptForKey {
                didPromptForKey = true
                showingKeySetup = true
            }
            return
        }
        needsKey = false

        let client = GeminiTextClient(apiKey: geminiKey)
        geminiTextClient = client
        speechPlayback = SpeechPlaybackController(client: SpeechClient(apiKey: geminiKey))
        let store = ConversationStore(context: modelContext)
        self.store = store

        // Primes the tutor with a recap: when resuming, of *that*
        // conversation specifically; otherwise of whatever happened most
        // recently. Either way this is the only continuity the model gets —
        // Gemini Live doesn't remember anything across connections.
        let recap = resuming.flatMap { store.recap(of: $0) } ?? store.recapOfMostRecentSession()
        let struggles = store.recentStruggleNotes().map { "\($0.phrase) — \($0.note)" }
        let config = LiveSessionConfig(
            systemInstruction: Prompts.systemPrompt(recap: recap, struggles: struggles)
        )
        session = VoiceSession(config: config, apiKey: geminiKey)

        let newCoordinator = ConversationCoordinator(translationService: TranslationService(client: client))
        // Persist a turn's translation/breakdown the moment it loads, so
        // reopening this conversation later never re-fetches it.
        newCoordinator.onTranslationLoaded = { [weak store] id, result in
            store?.updateTranslation(id: id, romaji: result.romaji, english: result.english)
        }
        newCoordinator.onBreakdownLoaded = { [weak store] id, phrases in
            store?.updateBreakdownCache(id: id, phrases: phrases)
        }
        // Seed the transcript so a resumed conversation reads continuously
        // rather than starting blank. Cached translations load instantly and
        // free; anything uncached is fetched once (bounded to this one
        // conversation) — see ConversationCoordinator.loadHistoricalSession.
        if let resuming {
            newCoordinator.loadHistoricalSession(resuming.turns.sorted { $0.timestamp < $1.timestamp })
        }
        coordinator = newCoordinator
    }
}

private struct ConversationBody: View {
    let session: VoiceSession
    let coordinator: ConversationCoordinator
    let store: ConversationStore
    let geminiTextClient: GeminiTextClient?
    let speechPlayback: SpeechPlaybackController
    /// Set when this screen is picking a past conversation back up — the
    /// first Start tap then reopens that one instead of creating a new one.
    let resuming: ConversationSession?
    /// Opens the API key screen — offered when a connection fails, since a
    /// rejected key is the most common cause.
    let onFixKey: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var persistedTurnIDs: Set<UUID> = []
    /// The turn whose breakdown is open in its own screen — looked up fresh
    /// from `coordinator.displayTurns` by id each time the sheet renders
    /// (rather than capturing the `DisplayTurn` value at tap time), so the
    /// sheet keeps updating as the breakdown loads in.
    @State private var selectedTurnID: UUID?
    /// Guards the auto-popup below from re-firing for the same turn if
    /// `session.turns` changes for some other reason without a new turn
    /// actually being appended.
    @State private var lastAutoShownModelTurnID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            StatusBar(session: session, onFixKey: onFixKey)
            transcriptTab
            Controls(session: session, store: store, geminiTextClient: geminiTextClient, resuming: resuming)
        }
        .onChange(of: session.turns) { _, newTurns in
            coordinator.sync(with: newTurns)
            persistNewTurns(newTurns)
            // Auto-open the breakdown for every fresh reply, rendered full
            // screen, so it's there to study the moment the tutor finishes
            // speaking rather than needing a manual tap. Only the newest
            // turn triggers this, and only once per turn — sync() above has
            // already kicked off its analysis (see
            // ConversationCoordinator.analyzeModelTurn), this just shows it.
            if let last = newTurns.last, last.speaker == .model, last.id != lastAutoShownModelTurnID {
                lastAutoShownModelTurnID = last.id
                selectedTurnID = last.id
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Leaving .active covers both the phone locking (stays
            // .inactive the whole time it's locked, never reaches
            // .background) and switching to another app (.inactive then
            // .background) — the mic should never keep listening in either
            // case just because Stop was never explicitly tapped.
            guard newPhase != .active else { return }
            endConversationIfActive(reason: "scenePhase -> \(newPhase)")
        }
        .onDisappear {
            // Leaving the screen used to leave this VoiceSession's
            // AVAudioEngine fully running while a brand new one spun up for
            // the next conversation — two engine instances contending for
            // the same shared AVAudioSession corrupted the negotiated format
            // down to 0 Hz and crashed on the very next `engine.connect(...)`.
            // Tearing down here, whenever this screen leaves the hierarchy
            // for any reason, is what guarantees only one is ever live — and
            // now that there's no explicit end-session control, it's also
            // the primary path that finalizes the conversation at all.
            endConversationIfActive(reason: "view disappeared")
        }
        .sheet(isPresented: Binding(
            get: { selectedTurnID != nil },
            set: { isPresented in if !isPresented { selectedTurnID = nil } }
        )) {
            if let selectedTurnID, let turn = coordinator.displayTurns.first(where: { $0.id == selectedTurnID }) {
                PhraseBreakdownView(
                    turn: turn,
                    speechPlayback: speechPlayback,
                    onRetryBreakdown: { coordinator.requestBreakdown(for: turn.id) }
                )
            }
        }
    }

    private func selectTurn(_ turn: DisplayTurn) {
        selectedTurnID = turn.id
        coordinator.requestBreakdown(for: turn.id)
    }

    /// Shared by the scenePhase and onDisappear handlers — both are "this
    /// screen isn't the one being actively used anymore" signals, and both
    /// need the exact same cleanup: tear down the live connection/audio
    /// engine and close out the persisted session, but only if one is
    /// actually open (a no-op if nothing was ever started, or if this fires
    /// twice — e.g. backgrounding and then leaving the screen).
    private func endConversationIfActive(reason: String) {
        guard session.phase != .idle else { return }
        debugLog("[DEBUG ConversationBody] \(reason), auto-ending conversation (was \(session.phase))")
        Task {
            await session.endConversation()
            if let geminiTextClient {
                store.endSession(extractingStrugglesWith: geminiTextClient)
            }
        }
    }

    private var transcriptTab: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(coordinator.displayTurns) { turn in
                        TurnCell(
                            turn: turn,
                            speechPlayback: speechPlayback,
                            onSelect: { selectTurn(turn) }
                        )
                        .id(turn.id)
                    }
                    PartialTranscriptCells(session: session, coordinator: coordinator)
                    // Fixed anchor at the very end of the content, past
                    // the partial cells — scrolling to a turn's own id
                    // isn't enough once there's live text below it.
                    Color.clear.frame(height: 1).id(Self.bottomAnchorID)
                }
                .padding()
            }
            .onChange(of: coordinator.revision) {
                scrollToBottom(proxy)
            }
            .onChange(of: session.partialUserText) {
                scrollToBottom(proxy)
            }
            .onChange(of: session.partialModelText) { _, newValue in
                coordinator.updateLivePreview(partialModelText: newValue)
                scrollToBottom(proxy)
            }
        }
    }

    private func persistNewTurns(_ turns: [Turn]) {
        for turn in turns where !persistedTurnIDs.contains(turn.id) {
            persistedTurnIDs.insert(turn.id)
            store.persist(turn, romaji: nil, english: nil)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }
}

private extension ConversationBody {
    static let bottomAnchorID = "conversation-bottom"
}

private struct StatusBar: View {
    let session: VoiceSession
    let onFixKey: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(phaseLabel)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(isFailed ? Brand.error : .white.opacity(0.88))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            if isFailed {
                Button("Check API Key", action: onFixKey)
                    .buttonStyle(PillButtonStyle())
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(Brand.torii)
                        .frame(width: geo.size.width * CGFloat(session.inputLevel))
                        .animation(.linear(duration: 0.05), value: session.inputLevel)
                }
            }
            .frame(height: 6)
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var isFailed: Bool {
        if case .failed = session.phase { return true }
        return false
    }

    private var statusColor: Color {
        switch session.phase {
        case .idle: return .white.opacity(0.4)
        case .connecting, .reconnecting: return Brand.sun
        case .failed: return Brand.error
        case .active: return session.isRecording ? Brand.toriiLight : Color(red: 0.45, green: 0.85, blue: 0.55)
        }
    }

    private var phaseLabel: String {
        switch session.phase {
        case .idle: return "Not connected"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .failed(let reason): return reason
        case .active: return session.isRecording ? "Listening…" : "Tap Start to talk"
        }
    }
}

/// Shown in place of the conversation when no Gemini key is saved — says
/// what's needed and why, instead of leaving a blank screen behind a sheet.
private struct MissingKeyView: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.fill")
                .font(.system(size: 40))
                .foregroundStyle(Brand.sun)
            Text("Add your Gemini API key")
                .font(.title3.bold())
                .foregroundStyle(.white)
            Text("Shimbashi talks to Google's Gemini using your own key, which you can get for free. It stays on this device.")
                .font(.footnote)
                .foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center)
            Button("Add API Key", action: onAdd)
                .buttonStyle(PillButtonStyle())
        }
        .padding(32)
    }
}

private struct PartialTranscriptCells: View {
    let session: VoiceSession
    let coordinator: ConversationCoordinator

    var body: some View {
        if !session.partialUserText.isEmpty {
            PartialCell(text: session.partialUserText, speaker: .user, translation: nil)
        }
        if !session.partialModelText.isEmpty {
            PartialCell(text: session.partialModelText, speaker: .model, translation: coordinator.livePartialTranslation)
        }
    }
}

/// A turn still being spoken — the Japanese line grows word by word as
/// Gemini transcribes it, and once there's enough of a sentence to work
/// with, romaji/English fill in underneath too (throttled, see
/// `ConversationCoordinator.updateLivePreview`), so you can follow along
/// rather than waiting for the whole turn to finish.
private struct PartialCell: View {
    let text: String
    let speaker: Turn.Speaker
    let translation: TranslationResult?

    var body: some View {
        VStack(alignment: speaker == .user ? .trailing : .leading, spacing: 4) {
            Text(text)
                .font(.body)
                .foregroundStyle(.white.opacity(0.85))

            if let translation {
                Text(translation.romaji)
                    .font(.subheadline)
                    .foregroundStyle(Brand.textSecondary)
                Text(translation.english)
                    .font(.footnote)
                    .foregroundStyle(Brand.textTertiary)
            }
        }
        .multilineTextAlignment(speaker == .user ? .trailing : .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Brand.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .frame(maxWidth: .infinity, alignment: speaker == .user ? .trailing : .leading)
        .padding(speaker == .user ? .leading : .trailing, 28)
    }
}

/// Push-to-talk, one centered button: "Start" begins recording one utterance
/// (connecting first if this is the very first one), "Stop" ends it and hands
/// off to the tutor's reply. Tapping "Start" again — whether the tutor is
/// still replying or already finished — both interrupts and begins the next
/// utterance; there's no separate interrupt control.
///
/// There's deliberately no "end session" control: leaving the screen (or
/// backgrounding the app) already tears the connection down and triggers the
/// summary/struggle extraction — see `ConversationBody.endConversationIfActive`
/// — so a button for it was redundant with simply navigating back.
private struct Controls: View {
    let session: VoiceSession
    let store: ConversationStore
    let geminiTextClient: GeminiTextClient?
    let resuming: ConversationSession?
    /// The saved conversation this screen created on its first Start. A
    /// later Start (after the phone locked, or a connection failed) reopens
    /// it rather than saving the follow-up as a second conversation — it's
    /// the same conversation on screen, so it must stay one in the list.
    @State private var ownSession: ConversationSession?

    var body: some View {
        Button {
            Task {
                if session.isRecording {
                    await session.endTurn()
                } else {
                    if session.phase == .idle || isFailed {
                        // Reopen the conversation being resumed (or the one this
                        // screen already started) rather than stranding its
                        // turns in a finished session and starting an empty
                        // one alongside it.
                        if let existing = resuming ?? ownSession {
                            store.resumeSession(existing)
                        } else {
                            ownSession = store.beginSession(closingDanglingSessionWith: geminiTextClient)
                        }
                    }
                    await session.beginTurn()
                }
            }
        }
        label: {
            Label(
                session.isRecording ? "Stop" : "Start",
                systemImage: session.isRecording ? "stop.fill" : "mic.fill"
            )
        }
        .buttonStyle(RecordButtonStyle(isRecording: session.isRecording))
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }

    private var isFailed: Bool {
        if case .failed = session.phase { return true }
        return false
    }
}

#Preview {
    NavigationStack { ConversationView() }
}
