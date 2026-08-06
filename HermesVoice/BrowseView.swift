import HermesKit
import SwiftUI

/// Connected home: profile picker + project/session browser.
struct BrowseView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                profileSection
                projectsSection
                recentsSection
            }
            .navigationTitle("Hermes Voice")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Disconnect") { model.disconnect() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.startConversation(cwd: nil) }
                    } label: {
                        Label("New conversation", systemImage: "waveform.badge.plus")
                    }
                }
            }
            .refreshable { await model.refreshProjects() }
        }
    }

    @ViewBuilder private var connectionSection: some View {
        if case .connecting = model.phase {
            Section {
                Label("Reconnecting…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
            }
        } else if case .disconnected(let reason) = model.phase {
            Section {
                Label(reason ?? "Disconnected", systemImage: "wifi.slash")
                    .foregroundStyle(.red)
            }
        }
    }

    private var profileSection: some View {
        Section("Profile") {
            if model.profilesLoading && model.profiles.isEmpty {
                HStack {
                    ProgressView()
                    Text("Loading profiles (this can take a while)…")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(model.profiles) { profile in
                Button {
                    Task { await model.selectProfile(profile.name) }
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            HStack(spacing: 6) {
                                Text(profile.name).font(.body.weight(.medium))
                                if profile.isDefault {
                                    Text("default")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                }
                            }
                            Text(profileSubtitle(profile))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.selectedProfile == profile.name {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func profileSubtitle(_ profile: ProfileInfo) -> String {
        var parts: [String] = []
        if let model = profile.model { parts.append(model) }
        if let provider = profile.provider { parts.append(provider) }
        if let skills = profile.skillCount { parts.append("\(skills) skills") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var projectsSection: some View {
        if let error = model.browseError {
            Section {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
        ForEach(model.projectTree?.projects ?? []) { project in
            Section(project.isHomeBucket ? "Home" : project.name) {
                if let path = project.primaryPath {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button {
                    Task {
                        await model.startConversation(
                            cwd: project.isHomeBucket ? nil : project.primaryPath)
                    }
                } label: {
                    Label(
                        project.isHomeBucket
                            ? "New conversation (no workspace)"
                            : "New conversation in project",
                        systemImage: "waveform.badge.plus")
                }
                ForEach(project.previewSessions) { session in
                    sessionRow(session)
                }
            }
        }
    }

    @ViewBuilder private var recentsSection: some View {
        if !model.recentSessions.isEmpty {
            Section("Recent sessions") {
                ForEach(model.recentSessions) { session in
                    sessionRow(session)
                }
            }
        }
    }

    private func sessionRow(_ session: SessionSummary) -> some View {
        Button {
            Task { await model.continueSession(session) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if session.pinned {
                        Image(systemName: "pin.fill").font(.caption2)
                    }
                    Text(session.title?.isEmpty == false ? session.title! : "Untitled session")
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let when = session.updatedAt {
                        Text(when, format: .relative(presentation: .named))
                    }
                    if let profile = session.profile {
                        Text(profile)
                    }
                    if let branch = session.gitBranch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
