import SwiftUI

/// Hidden text-path screen: proves the RPC layer without audio, and doubles
/// as a debugging console during voice conversations.
struct DevChatView: View {
    @Environment(\.dismiss) private var dismiss
    let controller: ConversationController
    @State private var draft = ""

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
                HStack {
                    TextField("Type a message", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(send)
                    Button("Send", action: send)
                        .buttonStyle(.borderedProminent)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
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

    private func send() {
        controller.submitTextPrompt(draft)
        draft = ""
    }
}
