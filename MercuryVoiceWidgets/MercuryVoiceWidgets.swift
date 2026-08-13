import ActivityKit
import SwiftUI
import WidgetKit

@main
struct MercuryVoiceWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ConversationLiveActivity()
    }
}

/// The lock-screen / Dynamic Island card for an active conversation
/// (issue #28): status at a glance plus mute, stop, and end buttons.
/// The buttons are LiveActivityIntents, so they act in the app process
/// without opening the app.
struct ConversationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ConversationActivityAttributes.self) { context in
            LockScreenCard(state: context.state)
                .padding()
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StatusBadge(state: context.state)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ControlRow(state: context.state)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.title ?? "Mercury Voice")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } compactLeading: {
                Image(systemName: statusSymbol(for: context.state))
                    .foregroundStyle(statusColor(for: context.state))
            } compactTrailing: {
                if context.state.muted {
                    Image(systemName: "mic.slash.fill").foregroundStyle(.red)
                } else {
                    Image(systemName: "waveform")
                }
            } minimal: {
                Image(systemName: statusSymbol(for: context.state))
                    .foregroundStyle(statusColor(for: context.state))
            }
        }
    }
}

private struct LockScreenCard: View {
    let state: ConversationActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(state.title ?? "Mercury Voice")
                    .font(.headline)
                    .lineLimit(1)
                StatusBadge(state: state)
            }
            Spacer()
            ControlRow(state: state)
        }
    }
}

private struct StatusBadge: View {
    let state: ConversationActivityAttributes.ContentState

    var body: some View {
        Label(statusLabel(for: state), systemImage: statusSymbol(for: state))
            .font(.caption.weight(.medium))
            .foregroundStyle(statusColor(for: state))
    }
}

/// Mute / stop / end, mirroring the in-app control row.
private struct ControlRow: View {
    let state: ConversationActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 10) {
            Button(intent: ToggleMuteIntent()) {
                Image(systemName: state.muted ? "mic.slash.fill" : "mic.fill")
                    .frame(width: 26, height: 26)
            }
            .tint(state.muted ? .red : .primary)
            Button(intent: StopSpeechIntent()) {
                Image(systemName: "stop.circle.fill")
                    .frame(width: 26, height: 26)
            }
            .tint(.orange)
            Button(intent: EndConversationIntent()) {
                Image(systemName: "phone.down.fill")
                    .frame(width: 26, height: 26)
            }
            .tint(.red)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .labelStyle(.iconOnly)
    }
}

private func statusLabel(for state: ConversationActivityAttributes.ContentState) -> String {
    if state.muted { return "Muted" }
    switch state.status {
    case "listening": return "Listening…"
    case "transcribing": return "Transcribing…"
    case "thinking": return "Thinking…"
    case "speaking": return "Speaking"
    default: return "Paused"
    }
}

private func statusSymbol(for state: ConversationActivityAttributes.ContentState) -> String {
    if state.muted { return "mic.slash.fill" }
    switch state.status {
    case "listening": return "mic.fill"
    case "transcribing": return "text.viewfinder"
    case "thinking": return "brain"
    case "speaking": return "speaker.wave.2.fill"
    default: return "pause.fill"
    }
}

private func statusColor(for state: ConversationActivityAttributes.ContentState) -> Color {
    if state.muted { return .red }
    switch state.status {
    case "listening": return .green
    case "transcribing": return .yellow
    case "thinking": return .purple
    case "speaking": return .blue
    default: return .gray
    }
}
