import SwiftUI

/// Sheet for creating a new playlist with a name field and a Public / Private
/// visibility toggle. Presented via `AppModel.showingNewPlaylistSheet` when the
/// user triggers ⌘N or taps the "+" button in the sidebar.
///
/// On confirm the sheet calls `AppModel.createPlaylist(name:isPublic:)` and
/// dismisses. An empty name disables the Create button — matching Finder's
/// inline-rename convention — so the sheet never sends a blank name to the
/// server.
struct NewPlaylistSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var isPublic: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New Playlist")
                .font(Theme.font(17, weight: .bold))
                .foregroundStyle(Theme.ink)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(Theme.font(11, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
                    .tracking(0.5)
                TextField("Playlist name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.font(13, weight: .regular))
                    // Submit via Return key mirrors inline-edit commit.
                    .onSubmit { commitIfValid() }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Visibility")
                    .font(Theme.font(11, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
                    .tracking(0.5)
                Picker("Visibility", selection: $isPublic) {
                    Label("Public", systemImage: "globe")
                        .tag(true)
                    Label("Private", systemImage: "lock.fill")
                        .tag(false)
                }
                .pickerStyle(.segmented)
                Text(isPublic
                    ? "Visible to all users on this server."
                    : "Only visible to you.")
                    .font(Theme.font(11, weight: .regular))
                    .foregroundStyle(Theme.ink3)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Create") { commitIfValid() }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private func commitIfValid() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        dismiss()
        Task { await model.createPlaylist(name: trimmed, isPublic: isPublic) }
    }
}
