import HermesKit
import SwiftUI

/// Connected home, split into three pages (issue #11):
///  1. profile picker
///  2. recent sessions for the selected profile, plus "new session" and
///     "choose a workspace" actions
///  3. workspaces, each listing that profile's sessions in the workspace
struct BrowseView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [Page] = []

    enum Page: Hashable {
        case sessions
        case workspaces
    }

    var body: some View {
        NavigationStack(path: $path) {
            profilesPage
                .navigationDestination(for: Page.self) { page in
                    switch page {
                    case .sessions: sessionsPage
                    case .workspaces: workspacesPage
                    }
                }
        }
    }

    // MARK: Page 1 — profiles

    private var profilesPage: some View {
        List {
            connectionSection
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
                        path.append(.sessions)
                        Task { await model.selectProfile(profile.name) }
                    } label: {
                        profileRow(profile)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Mercury Voice")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Disconnect") { model.disconnect() }
            }
        }
        .refreshable { await model.refreshProjects() }
    }

    private func profileRow(_ profile: ProfileInfo) -> some View {
        HStack {
            VStack(alignment: .leading) {
                HStack(spacing: 6) {
                    Text(profile.displayName).font(.body.weight(.medium))
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
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        // Whole row is the hit target, not just the text (issue #3).
        .contentShape(Rectangle())
    }

    private func profileSubtitle(_ profile: ProfileInfo) -> String {
        var parts: [String] = []
        if let model = profile.model { parts.append(model) }
        if let provider = profile.provider { parts.append(provider) }
        if let skills = profile.skillCount { parts.append("\(skills) skills") }
        return parts.joined(separator: " · ")
    }

    // MARK: Page 2 — sessions for the selected profile

    private var sessionsPage: some View {
        List {
            connectionSection
            Section {
                Button {
                    Task { await model.startConversation(cwd: nil) }
                } label: {
                    Label("New session", systemImage: "waveform.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                NavigationLink(value: Page.workspaces) {
                    Label("Choose a workspace", systemImage: "folder")
                }
            }
            errorSection
            Section("Recent sessions") {
                if model.browseLoading && model.recentSessions.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Loading sessions…").foregroundStyle(.secondary)
                    }
                } else if model.recentSessions.isEmpty {
                    Text("No sessions yet for this profile.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.recentSessions) { session in
                    sessionRow(session)
                }
            }
        }
        .navigationTitle(model.profileDisplayName(model.selectedProfile) ?? "Sessions")
        .refreshable { await model.refreshProjects() }
    }

    // MARK: Page 3 — workspaces

    private var workspacesPage: some View {
        List {
            errorSection
            if workspaces.isEmpty {
                Text("No workspaces yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(workspaces) { project in
                Section(project.name) {
                    if let path = project.primaryPath {
                        Text(path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Button {
                        Task { await model.startConversation(cwd: project.primaryPath) }
                    } label: {
                        Label("New session in workspace", systemImage: "waveform.badge.plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    ForEach(profileSessions(in: project)) { session in
                        sessionRow(session)
                    }
                }
            }
        }
        .navigationTitle("Workspaces")
        .refreshable { await model.refreshProjects() }
    }

    private var workspaces: [ProjectInfo] {
        (model.projectTree?.projects ?? []).filter { !$0.isHomeBucket }
    }

    /// Tree previews are cross-profile; keep only the selected profile's
    /// sessions (rows without a profile tag come from older backends — keep
    /// them rather than hide them).
    private func profileSessions(in project: ProjectInfo) -> [SessionSummary] {
        guard let selected = model.selectedProfile else { return project.previewSessions }
        return project.previewSessions.filter { $0.profile == nil || $0.profile == selected }
    }

    // MARK: Shared pieces

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

    @ViewBuilder private var errorSection: some View {
        if let error = model.browseError {
            Section {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
        // A token rotation mid-session can fail to write the keychain, and
        // this is the only screen on-screen when that happens (issue #9).
        if let warning = model.credentialStoreError {
            Section {
                Label(warning, systemImage: "key.slash")
                    .font(.callout)
                    .foregroundStyle(.orange)
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
            // Whole row is the hit target, not just the text (issue #3).
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
