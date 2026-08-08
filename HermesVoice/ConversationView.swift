import HermesKit
import SwiftUI
import VoiceEngine

/// The voice conversation screen: status orb, captions, tool ticker,
/// controls, and the approval/clarify sheets.
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    @Bindable var controller: ConversationController
    @State private var showDevChat = false
    #if os(iOS)
        @State private var showAudioDevices = false
    #endif

    /// All presentations share ONE sheet modifier. Stacking several
    /// sheet/alert modifiers on the same node faults ("Invalid
    /// Configuration") when two states overlap — approval and clarify can be
    /// pending at once, and prompts arrive while the dev sheet is open.
    /// Priority: approval > clarify > dev.
    private enum ActiveSheet: Identifiable {
        case approval(ApprovalRequest)
        case clarify(ClarifyRequest)
        case dev
        case audio

        var id: String {
            switch self {
            case .approval(let request): return "approval-\(request.sessionID)"
            case .clarify(let request): return "clarify-\(request.requestID)"
            case .dev: return "dev"
            case .audio: return "audio"
            }
        }
    }

    private var activeSheet: Binding<ActiveSheet?> {
        Binding(
            get: {
                if let approval = controller.approval { return .approval(approval) }
                if let clarify = controller.clarify { return .clarify(clarify) }
                if showDevChat { return .dev }
                #if os(iOS)
                    if showAudioDevices { return .audio }
                #endif
                return nil
            },
            set: { newValue in
                // Only the dev and audio sheets are interactively
                // dismissible; the prompt sheets clear through their respond
                // buttons.
                if newValue == nil {
                    showDevChat = false
                    #if os(iOS)
                        showAudioDevices = false
                    #endif
                }
            })
    }

    private var setupAlertPresented: Binding<Bool> {
        Binding(
            get: { controller.setupError != nil },
            set: { presented in
                if !presented { controller.clearSetupError() }
            })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer()
            StatusOrb(
                status: controller.voiceState.status,
                muted: controller.voiceState.muted,
                micLevel: controller.micLevel)
            Text(statusLabel)
                .font(.title3.weight(.medium))
                .padding(.top, 12)
                .contentTransition(.opacity)
            if let ticker = controller.toolTicker {
                Label(ticker, systemImage: "gearshape.2")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            Spacer()
            captions
            controls
        }
        .padding()
        .background(backgroundGradient.ignoresSafeArea())
        .sheet(item: activeSheet) { sheet in
            switch sheet {
            case .approval(let request):
                ApprovalSheet(request: request, controller: controller)
                    .interactiveDismissDisabled()
            case .clarify(let request):
                ClarifySheet(request: request, controller: controller)
                    .interactiveDismissDisabled()
            case .dev:
                DevChatView(controller: controller)
            case .audio:
                // Only reachable on iOS; macOS picks devices in Settings.
                #if os(iOS)
                    AudioDevicesSheet()
                        .presentationDetents([.medium])
                #else
                    EmptyView()
                #endif
            }
        }
        .onChange(of: controller.didEndByStopWord) { _, ended in
            if ended { model.endConversation() }
        }
        .alert(
            "Couldn't start the conversation",
            isPresented: setupAlertPresented
        ) {
            Button("Back") { model.endConversation() }
        } message: {
            Text(controller.setupError ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.sessionTitle ?? "New conversation")
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let profile = controller.profileName {
                        Label(profile, systemImage: "person.crop.circle")
                    }
                    if let project = controller.projectName {
                        Label(project, systemImage: "folder")
                    }
                    if !controller.connectionHealthy {
                        Label("reconnecting", systemImage: "wifi.exclamationmark")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            #if os(iOS)
                // macOS picks devices in Settings (⌘,); iOS needs an
                // in-conversation entry point.
                Button {
                    showAudioDevices = true
                } label: {
                    Image(systemName: "headphones")
                }
                .buttonStyle(.borderless)
                .help("Audio devices")
            #endif
            Button {
                showDevChat = true
            } label: {
                Image(systemName: "keyboard")
            }
            .buttonStyle(.borderless)
            .help("Text view (dev)")
            Button(role: .destructive) {
                model.endConversation()
            } label: {
                Text("End")
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: Captions

    private var captions: some View {
        VStack(spacing: 8) {
            if let notice = controller.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .onTapGesture { controller.clearNotice() }
            }
            if let transcript = controller.voiceState.lastTranscript {
                Text("“\(transcript)”")
                    .font(.callout.italic())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if !controller.assistantCaption.isEmpty {
                ScrollView {
                    Text(controller.assistantCaption)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 130)
                .defaultScrollAnchor(.bottom)
            }
        }
        .padding(.bottom, 16)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 28) {
            ControlButton(
                symbol: controller.voiceState.muted ? "mic.slash.fill" : "mic.fill",
                label: controller.voiceState.muted ? "Unmute" : "Mute",
                tint: controller.voiceState.muted ? .red : .primary
            ) {
                controller.toggleMute()
            }

            ControlButton(
                symbol: "checkmark.circle.fill",
                label: "End turn",
                tint: controller.voiceState.status == .listening ? .green : .secondary
            ) {
                controller.endTurnNow()
            }
            .disabled(controller.voiceState.status != .listening)

            ControlButton(symbol: "stop.circle.fill", label: "Stop", tint: .orange) {
                controller.stopSpeech()
            }
        }
        .padding(.bottom, 8)
    }

    private var statusLabel: String {
        if controller.voiceState.paused { return "Waiting for you…" }
        if controller.voiceState.muted { return "Muted" }
        switch controller.voiceState.status {
        case .idle: return "Paused"
        case .listening: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking"
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [statusColor.opacity(0.15), Color.clear],
            startPoint: .top, endPoint: .center)
    }

    private var statusColor: Color {
        switch controller.voiceState.status {
        case .idle: return .gray
        case .listening: return .green
        case .transcribing: return .yellow
        case .thinking: return .purple
        case .speaking: return .blue
        }
    }
}

// MARK: - Status orb

struct StatusOrb: View {
    var status: ConversationStatus
    var muted: Bool
    var micLevel: Double

    @State private var pulse = false

    private var color: Color {
        if muted { return .red }
        switch status {
        case .idle: return .gray
        case .listening: return .green
        case .transcribing: return .yellow
        case .thinking: return .purple
        case .speaking: return .blue
        }
    }

    private var symbol: String {
        if muted { return "mic.slash.fill" }
        switch status {
        case .idle: return "pause.fill"
        case .listening: return "mic.fill"
        case .transcribing: return "text.viewfinder"
        case .thinking: return "brain"
        case .speaking: return "speaker.wave.2.fill"
        }
    }

    var body: some View {
        ZStack {
            // Live level ring while listening.
            Circle()
                .fill(color.opacity(0.18))
                .frame(width: 180, height: 180)
                .scaleEffect(
                    status == .listening
                        ? 1 + min(0.35, micLevel * 1.2)
                        : (pulse ? 1.12 : 0.96))
                .animation(.easeOut(duration: 0.08), value: micLevel)
                .animation(
                    .easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
            Circle()
                .fill(color.gradient)
                .frame(width: 120, height: 120)
                .shadow(color: color.opacity(0.45), radius: 24)
            Image(systemName: symbol)
                .font(.system(size: 42))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
        }
        .onAppear { pulse = true }
    }
}

struct ControlButton: View {
    var symbol: String
    var label: String
    var tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 28))
                Text(label).font(.caption)
            }
            .frame(width: 76, height: 68)
        }
        .buttonStyle(.bordered)
        .tint(tint)
    }
}

// MARK: - Approval / clarify sheets

struct ApprovalSheet: View {
    let request: ApprovalRequest
    let controller: ConversationController

    private func choiceLabel(_ choice: String) -> String {
        switch choice {
        case "once": return "Allow once"
        case "session": return "Allow this session"
        case "always": return "Always allow"
        case "deny": return "Deny"
        default: return choice
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Approval needed", systemImage: "exclamationmark.shield")
                .font(.title2.bold())
            if let description = request.description {
                Text(description).foregroundStyle(.secondary)
            }
            if let command = request.command {
                ScrollView(.horizontal) {
                    Text(command)
                        .font(.system(.callout, design: .monospaced))
                        .padding(8)
                }
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(spacing: 8) {
                ForEach(request.choices, id: \.self) { choice in
                    Button {
                        controller.respondApproval(choice: choice)
                    } label: {
                        Text(choiceLabel(choice)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(choice == "deny" ? .red : .accentColor)
                }
            }
        }
        .padding(24)
        #if os(macOS)
            .frame(minWidth: 420)
        #else
            .presentationDetents([.medium])
        #endif
    }
}

struct ClarifySheet: View {
    let request: ClarifyRequest
    let controller: ConversationController
    @State private var freeText = ""
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Hermes asks", systemImage: "questionmark.bubble")
                .font(.title2.bold())
            Text(request.question)

            if request.choices.isEmpty {
                TextField("Your answer", text: $freeText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { controller.respondClarify(answer: freeText) }
                Button("Send") { controller.respondClarify(answer: freeText) }
                    .buttonStyle(.borderedProminent)
            } else if request.multiSelect {
                ForEach(request.choices, id: \.self) { choice in
                    Toggle(
                        choice,
                        isOn: Binding(
                            get: { selected.contains(choice) },
                            set: { on in
                                if on { selected.insert(choice) } else { selected.remove(choice) }
                            }))
                }
                Button("Send") {
                    controller.respondClarify(
                        answer: request.choices.filter(selected.contains)
                            .joined(separator: ", "))
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            } else {
                ForEach(request.choices, id: \.self) { choice in
                    Button {
                        controller.respondClarify(answer: choice)
                    } label: {
                        Text(choice).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Button("Skip") { controller.respondClarify(answer: "") }
                .buttonStyle(.borderless)
        }
        .padding(24)
        #if os(macOS)
            .frame(minWidth: 420)
        #else
            .presentationDetents([.medium])
        #endif
    }
}
