import SwiftUI
@preconcurrency import JellifyCore

/// Left-rail navigation + user library summary.
///
/// BATCH-06b (#71 / #75): the "Your Library" block now surfaces the user's
/// playlists inline, with a ⌘N shortcut that drops a fresh row into edit
/// mode, a right-click context menu for rename / duplicate / delete, and a
/// confirmation dialog for destructive delete. All of the wiring lives on
/// `AppModel` (see `sidebarEditingPlaylistId`, `beginNewPlaylist`,
/// `commitSidebarPlaylistEdit`, etc.) so the view stays compact.
struct Sidebar: View {
    @Environment(AppModel.self) private var model

    /// The playlist row currently hovered by the pointer. Used to reveal
    /// the subtle trailing affordances (copying spinner slot); `nil` when
    /// nothing is hovered.
    @State private var hoveredPlaylistId: String?

    /// Focus binding for the inline TextField. Bound to whichever row
    /// (new-placeholder or existing-rename) is currently in edit mode.
    @FocusState private var editFieldFocused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            // Brand
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: [Theme.teal, Theme.primary], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 30, height: 30)
                    .overlay(Text("🪼").font(.system(size: 16)))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Jellify")
                        .font(Theme.font(15, weight: .black, italic: true))
                        .foregroundStyle(Theme.ink)
                    Text("DESKTOP")
                        .font(Theme.font(9, weight: .bold))
                        .foregroundStyle(Theme.ink3)
                        .tracking(1.5)
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Primary nav
            VStack(alignment: .leading, spacing: 2) {
                navItem("house", label: "Home", screen: .home)
                navItem("music.note.list", label: "Library", screen: .library)
                navItem("magnifyingglass", label: "Search", screen: .search)
            }
            .padding(.horizontal, 10)

            // Stats header. Keep the aggregate "Albums / Artists / Playlists"
            // summary rows above the playlist list so the count glance stays
            // in place; the playlist list lives as its own section below.
            sectionHeader("Your Library")
            VStack(alignment: .leading, spacing: 2) {
                libRow("heart", label: "Favorites", count: nil)
                libRow("square.stack", label: "Albums", count: UInt32(model.albums.count))
                libRow("person.crop.circle", label: "Artists", count: UInt32(model.artists.count))
                libRow("music.note.list", label: "Playlists", count: UInt32(model.playlists.count))
            }
            .padding(.horizontal, 10)

            // Playlist list — scrolls independently if the user has a long
            // library. Capped to a reasonable chunk of sidebar height so
            // the server footer stays anchored at the bottom.
            playlistsSection
                .padding(.horizontal, 10)
                .padding(.top, 6)

            Spacer(minLength: 0)

            // Server footer
            HStack(spacing: 10) {
                Circle().fill(Theme.teal).frame(width: 8, height: 8)
                    .shadow(color: Theme.teal.opacity(0.7), radius: 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.session?.server.name ?? "—")
                        .font(Theme.font(11, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text("Connected · \(model.albums.count) albums")
                        .font(Theme.font(10, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                }
                Spacer()
                Button { model.logout() } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .foregroundStyle(Theme.ink3)
                }
                .buttonStyle(.plain)
                .help("Sign out")
                .accessibilityLabel("Sign out")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Divider().background(Theme.border), alignment: .top)
        }
        .frame(width: 252)
        // Translucent Apple-Music-style sidebar material. The `.sidebar`
        // material + `.behindWindow` blending lets the desktop wallpaper
        // tint through while preserving the brand backdrop on top. See
        // issues #9 / #10 / #28.
        .background(
            VisualEffectView(material: .sidebar)
                .overlay(Theme.bgAlt.opacity(0.55))
        )
        // The ⌘N keyboard shortcut lives on the File → "New Playlist"
        // menu item declared in `JellifyApp.JellifyCommands` so it's
        // discoverable via the menu bar. The "+" button in the playlist
        // list header drives the same action from the sidebar itself.
    }

    // MARK: - Playlist list section

    @ViewBuilder
    private var playlistsSection: some View {
        let editingNew = model.sidebarEditingPlaylistId == AppModel.sidebarNewPlaylistSentinel
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("PLAYLISTS")
                    .font(Theme.font(10, weight: .bold))
                    .foregroundStyle(Theme.ink3)
                    .tracking(1.5)
                Spacer()
                Button { model.beginNewPlaylist() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.ink3)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("New Playlist (⌘N)")
                .disabled(model.session == nil)
                .accessibilityLabel("New Playlist")
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)
            .padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    // In-progress new-playlist row, shown at the top so the
                    // user sees where the new item will land.
                    if editingNew {
                        newPlaylistEditRow
                    }
                    ForEach(model.playlists, id: \.id) { playlist in
                        playlistRow(playlist)
                    }
                }
            }
            // Reasonable ceiling so a user with hundreds of playlists
            // doesn't push the server footer off-screen. Scroll handles
            // the overflow.
            .frame(maxHeight: 280)
        }
    }

    // MARK: - Playlist row (display + inline edit)

    @ViewBuilder
    private func playlistRow(_ playlist: Playlist) -> some View {
        let isEditing = model.sidebarEditingPlaylistId == playlist.id
        let isActiveScreen: Bool = {
            if case .playlist(let id) = model.screen { return id == playlist.id }
            return false
        }()
        let isCopying = model.sidebarCopyingPlaylistIds.contains(playlist.id)
        let isHovering = hoveredPlaylistId == playlist.id

        HStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .foregroundStyle(isActiveScreen ? Theme.accent : Theme.ink2)
                .frame(width: 18)

            if isEditing {
                editTextField(initialText: playlist.name)
            } else {
                Text(playlist.name)
                    .font(Theme.font(12, weight: isActiveScreen ? .bold : .medium))
                    .foregroundStyle(isActiveScreen ? Theme.ink : Theme.ink2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            if isCopying {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                    .tint(Theme.ink3)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    isActiveScreen
                        ? Theme.surface2
                        : (isHovering ? Theme.rowHover : .clear)
                )
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredPlaylistId = hovering ? playlist.id : (hoveredPlaylistId == playlist.id ? nil : hoveredPlaylistId)
        }
        .onTapGesture {
            // Tap on a non-editing row navigates. Tapping on a row in edit
            // mode is intercepted by the TextField itself; this branch is a
            // guard for the rare case the gesture fires before the field
            // takes focus.
            guard !isEditing else { return }
            model.goToPlaylist(playlist)
        }
        .contextMenu { PlaylistContextMenu(playlist: playlist) }
        .accessibilityLabel(playlist.name)
        .accessibilityAddTraits(isActiveScreen ? .isSelected : [])
    }

    // MARK: - Inline edit TextField (shared by Cmd+N and Rename)

    @ViewBuilder
    private var newPlaylistEditRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .foregroundStyle(Theme.accent)
                .frame(width: 18)
            editTextField(initialText: "")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    /// Inline TextField bound to `AppModel.sidebarEditingDraft`. Used both
    /// by the new-playlist row and the rename-in-place affordance. On
    /// commit (Return) the draft is fed to `commitSidebarPlaylistEdit`; on
    /// Escape the edit is cancelled. On blur without any edit change (i.e.
    /// the draft still matches `initialText`) we also treat it as cancel to
    /// match macOS Finder's inline-rename behaviour.
    @ViewBuilder
    private func editTextField(initialText: String) -> some View {
        @Bindable var model = model
        TextField("Playlist name", text: $model.sidebarEditingDraft)
            .textFieldStyle(.plain)
            .font(Theme.font(12, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .focused($editFieldFocused)
            .onAppear {
                // Seed the draft with the passed-in initial text so existing
                // playlists open their rename field prefilled. The new-row
                // case passes an empty string and should stay empty.
                if !initialText.isEmpty && model.sidebarEditingDraft.isEmpty {
                    model.sidebarEditingDraft = initialText
                }
                // Defer focus by a tick so the field has mounted.
                DispatchQueue.main.async { editFieldFocused = true }
            }
            .onSubmit {
                Task { await model.commitSidebarPlaylistEdit() }
            }
            .onExitCommand {
                // Escape cancels the edit without committing.
                model.cancelSidebarPlaylistEdit()
            }
            .onChange(of: editFieldFocused) { _, focused in
                // Blur without an active commit → treat as cancel (empty) or
                // commit (non-empty unchanged draft). The committer itself
                // trims and ignores empty values.
                guard !focused else { return }
                // If the edit was already cleared elsewhere (e.g. Escape),
                // there's nothing to do.
                guard model.sidebarEditingPlaylistId != nil else { return }
                let trimmed = model.sidebarEditingDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    model.cancelSidebarPlaylistEdit()
                } else {
                    Task { await model.commitSidebarPlaylistEdit() }
                }
            }
    }

    @ViewBuilder
    private func navItem(_ icon: String, label: String, screen: AppModel.Screen) -> some View {
        let active = model.screen == screen
        Button { model.screen = screen } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(active ? Theme.accent : Theme.ink2)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(label)
                    .font(Theme.font(13, weight: active ? .bold : .semibold))
                    .foregroundStyle(active ? Theme.ink : Theme.ink2)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(active ? Theme.surface2 : .clear)
            )
            .overlay(alignment: .leading) {
                if active {
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(width: 3)
                        .clipShape(RoundedRectangle(cornerRadius: 1))
                        .padding(.vertical, 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // VoiceOver announces a simple "Home" / "Library" / "Search" and,
        // for the currently selected tab, adds the "selected" trait so the
        // user hears which one they're on without parsing visual chrome.
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private func libRow(_ icon: String, label: String, count: UInt32?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Theme.ink2)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(label)
                .font(Theme.font(13, weight: .semibold))
                .foregroundStyle(Theme.ink2)
            Spacer()
            if let c = count {
                Text("\(c)")
                    .font(Theme.font(10, weight: .bold))
                    .foregroundStyle(Theme.ink3)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // Combine icon + label + count into one VoiceOver utterance so the
        // row reads as "Albums, 42" rather than three separate fragments.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(count.map { "\(label), \($0)" } ?? label)
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Theme.font(10, weight: .bold))
            .foregroundStyle(Theme.ink3)
            .tracking(1.5)
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 6)
    }
}
