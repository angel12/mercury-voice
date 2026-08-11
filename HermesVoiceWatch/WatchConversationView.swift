import HermesKit
import SwiftUI
import VoiceEngine

/// The live conversation on the wrist: status orb, last transcript /
/// caption, and the mute / listen / stop controls, with the same
/// approval/clarify prompts as the phone in watch-sized sheets.
struct WatchConversationView: View {
    @Environment(AppModel.self) private var model
    @Bindable var controller: ConversationController

    /// Approval and clarify share one sheet slot (matching the iOS view):
    /// stacked sheet modifiers fault when both prompts are pending at once.
    private enum ActiveSheet: Identifiable {
        case approval(ApprovalRequest)
        case clarify(ClarifyRequest)

        var id: String {
            switch self {
            case .approval(let request): return "approval-\(request.sessionID)"
            case .clarify(let request): return "clarify-\(request.requestID)"
            }
        }
    }

    private var activeSheet: Binding<ActiveSheet?> {
        Binding(
            get: {
                if let approval = controller.approval { return .approval(approval) }
                if let clarify = controller.clarify { return .clarify(clarify) }
                return nil
            },
            set: { _ in /* prompts clear through their respond buttons */ })
    }

    private var setupAlertPresented: Binding<Bool> {
        Binding(
            get: { controller.setupError != nil },
            set: { presented in
                if !presented { controller.clearSetupError() }
            })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    WatchStatusOrb(
                        status: controller.voiceState.status,
                        muted: controller.voiceState.muted,
                        micLevel: controller.micLevel)
                    Text(statusLabel)
                        .font(.footnote.weight(.medium))
                        .contentTransition(.opacity)
                    if let ticker = controller.toolTicker {
                        Text(ticker)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !controller.connectionHealthy {
                        Label("reconnecting", systemImage: "wifi.exclamationmark")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if let notice = controller.notice {
                        Text(notice)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .onTapGesture { controller.clearNotice() }
                    }
                    if let transcript = controller.voiceState.lastTranscript {
                        Text("“\(transcript)”")
                            .font(.caption.italic())
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    if !controller.assistantCaption.isEmpty {
                        Text(controller.assistantCaption)
                            .font(.caption)
                            .lineLimit(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    controls
                        .padding(.top, 4)

                    Button(role: .destructive) {
                        model.endConversation()
                    } label: {
                        Label("End", systemImage: "xmark.circle.fill")
                    }
                    .padding(.top, 4)
                }
            }
            .navigationTitle(controller.sessionTitle ?? "Hermes")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(item: activeSheet) { sheet in
            switch sheet {
            case .approval(let request):
                WatchApprovalSheet(request: request, controller: controller)
                    .interactiveDismissDisabled()
            case .clarify(let request):
                WatchClarifySheet(request: request, controller: controller)
                    .interactiveDismissDisabled()
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

    private var controls: some View {
        HStack(spacing: 8) {
            WatchControlButton(
                symbol: controller.voiceState.muted ? "mic.slash.fill" : "mic.fill",
                tint: controller.voiceState.muted ? .red : .primary
            ) {
                controller.toggleMute()
            }

            if canListen {
                WatchControlButton(symbol: "waveform.circle.fill", tint: .green) {
                    controller.listenNow()
                }
            } else {
                WatchControlButton(
                    symbol: "checkmark.circle.fill",
                    tint: controller.voiceState.status == .listening ? .green : .secondary
                ) {
                    controller.endTurnNow()
                }
                .disabled(controller.voiceState.status != .listening)
            }

            WatchControlButton(symbol: "stop.circle.fill", tint: .orange) {
                controller.stopSpeech()
            }
        }
    }

    /// Same idle-lull rule as the iOS view (issues #17/#31): after Stop or a
    /// stranded pause the middle button becomes the way back to listening.
    private var canListen: Bool {
        controller.voiceState.status == .idle
            && !controller.voiceState.muted
            && controller.approval == nil
            && controller.clarify == nil
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
}

// MARK: - Status orb (watch-sized)

struct WatchStatusOrb: View {
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
            Circle()
                .fill(color.opacity(0.18))
                .frame(width: 72, height: 72)
                .scaleEffect(
                    status == .listening
                        ? 1 + min(0.3, micLevel * 1.2)
                        : (pulse ? 1.1 : 0.96))
                .animation(.easeOut(duration: 0.08), value: micLevel)
                .animation(
                    .easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
            Circle()
                .fill(color.gradient)
                .frame(width: 52, height: 52)
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
        }
        .onAppear { pulse = true }
    }
}

struct WatchControlButton: View {
    var symbol: String
    var tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(tint)
    }
}

// MARK: - Approval / clarify sheets

struct WatchApprovalSheet: View {
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
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Label("Approval needed", systemImage: "exclamationmark.shield")
                    .font(.headline)
                if let description = request.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let command = request.command {
                    Text(command)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(4)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
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
    }
}

struct WatchClarifySheet: View {
    let request: ClarifyRequest
    let controller: ConversationController
    @State private var freeText = ""
    @State private var selected: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Label("Hermes asks", systemImage: "questionmark.bubble")
                    .font(.headline)
                Text(request.question)
                    .font(.caption)

                if request.choices.isEmpty {
                    // The watch text field offers dictation and scribble.
                    TextField("Your answer", text: $freeText)
                    Button("Send") { controller.respondClarify(answer: freeText) }
                        .buttonStyle(.borderedProminent)
                } else if request.multiSelect {
                    ForEach(request.choices, id: \.self) { choice in
                        Toggle(
                            choice,
                            isOn: Binding(
                                get: { selected.contains(choice) },
                                set: { on in
                                    if on {
                                        selected.insert(choice)
                                    } else {
                                        selected.remove(choice)
                                    }
                                }))
                        .font(.caption)
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
            }
        }
    }
}
