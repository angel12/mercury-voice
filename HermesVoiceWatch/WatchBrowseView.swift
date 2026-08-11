import HermesKit
import SwiftUI

/// Compact browse screen: start a session (with a profile picker) or
/// continue a recent one. Mirrors the essentials of the iOS BrowseView.
struct WatchBrowseView: View {
    @Environment(AppModel.self) private var model
    @State private var starting = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        starting = true
                        Task {
                            await model.startConversation(cwd: nil)
                            starting = false
                        }
                    } label: {
                        Label("New Session", systemImage: "waveform.circle.fill")
                            .font(.headline)
                    }
                    .disabled(starting)

                    if model.profiles.count > 1 {
                        NavigationLink {
                            profilePicker
                        } label: {
                            Label(
                                model.selectedProfile ?? "Profile",
                                systemImage: "person.crop.circle")
                        }
                    }
                }

                if !model.recentSessions.isEmpty {
                    Section("Recent") {
                        ForEach(model.recentSessions.prefix(8), id: \.storedID) { session in
                            Button {
                                starting = true
                                Task {
                                    await model.continueSession(session)
                                    starting = false
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.title?.isEmpty == false
                                        ? session.title! : "Untitled")
                                        .lineLimit(2)
                                    if let profile = session.profile {
                                        Text(profile)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(starting)
                        }
                    }
                } else if model.browseLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }

                if let error = model.browseError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Section {
                    Button(role: .destructive) {
                        model.disconnect()
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
                }
            }
            .navigationTitle(model.endpoint?.displayName ?? "Hermes")
        }
    }

    private var profilePicker: some View {
        List(model.profiles, id: \.name) { profile in
            Button {
                Task { await model.selectProfile(profile.name) }
            } label: {
                HStack {
                    Text(profile.name)
                    Spacer()
                    if model.selectedProfile == profile.name {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
        .navigationTitle("Profile")
    }
}
