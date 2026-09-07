import SwiftUI

/// Hidden text-path screen: proves the RPC layer without audio, and doubles
/// as a debugging console during voice conversations.
struct DevChatView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var controller: ConversationController

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(controller.devMessages) { message in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(message.role == "user" ? "You" : "Hermes")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                                Text(message.text)
                                    .textSelection(.enabled)
                            }
                            .frame(
                                maxWidth: .infinity,
                                alignment: message.role == "user" ? .trailing : .leading)
                        }
                        if !controller.assistantCaption.isEmpty,
                            controller.devMessages.last?.text != controller.assistantCaption
                        {
                            Text(controller.assistantCaption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                }
                .defaultScrollAnchor(.bottom)

                Divider()
                if let pending = controller.pendingText {
                    VStack(alignment: .leading) {
                        ProgressView("Sending…")
                        Text(pending).textSelection(.enabled)
                    }
                    .padding()
                }
                if let error = controller.textSubmissionError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).foregroundStyle(.red)
                        if let failed = controller.failedText {
                            Text(failed).textSelection(.enabled)
                            Button("Retry message") {
                                controller.submitTextPrompt(failed)
                            }
                            .disabled(controller.pendingText != nil)
                            Button("Dismiss failed message", action: controller.dismissFailedText)
                                .disabled(controller.pendingText != nil)
                            Text("Retry or dismiss this message before sending another.")
                                .font(.caption)
                        }
                    }
                    .padding()
                }
                HStack {
                    TextField("Type a message", text: $controller.textDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(send)
                    Button("Send", action: send)
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            controller.pendingText != nil || controller.failedText != nil
                                || controller.textDraft.trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                ).isEmpty)
                }
                .padding()
            }
            .navigationTitle("Text")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 460, minHeight: 480)
        #endif
    }

    func send() {
        controller.submitTextPrompt(controller.textDraft)
    }
}
