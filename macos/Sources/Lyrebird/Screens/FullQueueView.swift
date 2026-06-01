import SwiftUI
@preconcurrency import LyrebirdCore

/// Full-page Play Queue view (⌘U, #81). A larger-format counterpart to the
/// 320pt `QueueInspector` drawer, suited to bulk review of what's coming and
/// what just played. Pushed onto `navPath` as `Route.fullQueue` and rendered
/// by `MainShell`; ⌘U toggles it via `AppModel.toggleFullQueue`.
///
/// Layout (top → bottom):
///   1. **Header** — title + "Save Queue as Playlist" action.
///   2. **Recently in this session** — up to 50 tracks played earlier in
///      *this app session* (newest first), drawn from `sessionPlayHistory`.
///      Matches Spotify's "history above the now-playing line" affordance so
///      the user can re-queue something they just heard.
///   3. **Now Playing** — the currently-playing track.
///   4. **Up Next** — the user-added queue (`upNextUserAdded`).
///   5. **Playing From {source}** — the auto-queue tail (`upNextAutoQueue`).
///
/// Reorder / drag affordances stay in the inspector (#80); this page is a
/// read-and-bulk-act surface, so rows are click-to-play with a context menu
/// rather than draggable. "Save Queue as Playlist" reuses the same
/// `AppModel.saveQueueAsPlaylist(name:)` path the inspector's Save uses, so
/// error surfacing + the older-server top-up behaviour come for free.
struct FullQueueView: View {
    @Environment(AppModel.self) private var model

    @State private var showSaveSheet = false
    @State private var saveDraftName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if !model.sessionPlayHistory.isEmpty {
                    sessionHistorySection
                }
                nowPlayingSection
                upNextSection
                playingFromSection
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        // Save-queue sheet. Mirrors the inspector's flow so the two Save
        // entry points behave identically. Kept local to this view — the
        // shared work is `saveQueueAsPlaylist(name:)` on the model.
        .sheet(isPresented: $showSaveSheet, onDismiss: { saveDraftName = "" }) {
            FullQueueSaveSheet(
                name: $saveDraftName,
                trackCount: saveTrackCount,
                onCancel: { showSaveSheet = false },
                onSave: {
                    let trimmed = saveDraftName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    showSaveSheet = false
                    Task { await model.saveQueueAsPlaylist(name: trimmed) }
                }
            )
            .environment(model)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Play Queue")
                    .font(Theme.font(28, weight: .black))
                    .foregroundStyle(Theme.ink)
                Text(queueSummary)
                    .font(Theme.font(12, weight: .medium))
                    .foregroundStyle(Theme.ink3)
            }
            Spacer()
            Button(action: beginSave) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Save Queue as Playlist")
                        .font(Theme.font(12, weight: .semibold))
                }
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(saveTrackCount == 0)
            .accessibilityLabel("Save Queue as Playlist")
            .accessibilityHint("Creates a new playlist from the current queue")
        }
    }

    /// One-line summary of the queue size, e.g. "12 up next · 8 played this
    /// session". Reads as a stable status line under the title.
    private var queueSummary: String {
        let upcoming = model.upNextUserAdded.count + model.upNextAutoQueue.count
        let played = model.sessionPlayHistory.count
        var parts: [String] = []
        parts.append("\(upcoming) up next")
        if played > 0 { parts.append("\(played) played this session") }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - Recently in this session (#81)

    @ViewBuilder
    private var sessionHistorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Recently in this session")
            VStack(spacing: 2) {
                ForEach(Array(model.sessionPlayHistory.enumerated()), id: \.offset) { _, track in
                    FullQueueTrackRow(track: track, queue: model.sessionPlayHistory)
                }
            }
        }
    }

    // MARK: - Now Playing

    @ViewBuilder
    private var nowPlayingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Now Playing")
            if let track = model.status.currentTrack {
                FullQueueTrackRow(track: track, queue: [track])
            } else {
                emptyRow("Nothing is playing.")
            }
        }
    }

    // MARK: - Up Next

    @ViewBuilder
    private var upNextSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Up Next")
            if model.upNextUserAdded.isEmpty {
                emptyRow("Nothing queued. Use \u{2318}-click \u{2192} Play Next on a track.")
            } else {
                VStack(spacing: 2) {
                    ForEach(model.upNextUserAdded) { entry in
                        FullQueueTrackRow(
                            track: entry.track,
                            queue: model.upNextUserAdded.map(\.track)
                        )
                    }
                }
            }
        }
    }

    // MARK: - Playing From

    @ViewBuilder
    private var playingFromSection: some View {
        if !model.upNextAutoQueue.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader(playingFromTitle)
                VStack(spacing: 2) {
                    ForEach(model.upNextAutoQueue) { entry in
                        FullQueueTrackRow(
                            track: entry.track,
                            queue: model.upNextAutoQueue.map(\.track)
                        )
                    }
                }
            }
        }
    }

    private var playingFromTitle: String {
        if let name = model.currentContext?.name, !name.isEmpty {
            return "Playing From \(name)"
        }
        return "Playing From Queue"
    }

    // MARK: - Actions

    /// Number of tracks the Save action would write: current + user-added +
    /// auto tail. Drives the disabled state and the sheet's count copy.
    /// History is intentionally excluded — Save persists what's queued, not
    /// what already played, matching the inspector's Save semantics.
    private var saveTrackCount: Int {
        let current = model.status.currentTrack == nil ? 0 : 1
        return current + model.upNextUserAdded.count + model.upNextAutoQueue.count
    }

    private func beginSave() {
        saveDraftName = defaultPlaylistName()
        showSaveSheet = true
    }

    private func defaultPlaylistName() -> String {
        if let name = model.currentContext?.name, !name.isEmpty {
            return "\(name) + Up Next"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Queue \(formatter.string(from: Date()))"
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Theme.font(11, weight: .bold))
            .foregroundStyle(Theme.ink2)
            .tracking(1.5)
            .textCase(.uppercase)
    }

    @ViewBuilder
    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(Theme.font(12, weight: .medium))
            .foregroundStyle(Theme.ink3)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Row

/// One track row in the full-page queue. Click plays the track in the
/// context of its surrounding list (`queue`) so auto-advance continues
/// naturally — the same contract `TopTrackRow` uses. Right-click surfaces
/// the shared `TrackContextMenu` (Play Next / Add to Queue / favorite / …).
private struct FullQueueTrackRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let track: Track
    /// The list this row belongs to, passed to `play(tracks:startIndex:)` so
    /// playback continues through the rest of the section.
    let queue: [Track]

    @State private var isHovering = false

    private var isActive: Bool {
        model.status.currentTrack?.id == track.id
    }
    private var isPlaying: Bool {
        isActive && model.status.state == .playing
    }

    var body: some View {
        Button(action: playFromHere) {
            HStack(spacing: 12) {
                ZStack {
                    if isPlaying {
                        EqualizerIcon()
                            .foregroundStyle(Theme.accent)
                    } else if isHovering {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.ink)
                    } else {
                        Artwork(
                            url: model.imageURL(
                                for: track.albumId ?? track.id,
                                tag: track.imageTag,
                                maxWidth: 120
                            ),
                            seed: track.albumName ?? track.name,
                            size: 40,
                            radius: 4
                        )
                        .frame(width: 40, height: 40)
                    }
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name)
                        .font(Theme.font(13, weight: .semibold))
                        .foregroundStyle(isActive ? Theme.accent : Theme.ink)
                        .lineLimit(1)
                    Text(track.artistName)
                        .font(Theme.font(11, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if let album = track.albumName, !album.isEmpty {
                    Text(album)
                        .font(Theme.font(11, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                        .frame(maxWidth: 220, alignment: .trailing)
                }

                Text(track.durationFormatted)
                    .font(Theme.font(12, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .monospacedDigit()
                    .frame(minWidth: 42, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Theme.surface2 : (isHovering ? Theme.rowHover : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            }
        }
        .contextMenu { TrackContextMenu(selection: [track]) }
        .focusable(true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(track.name) by \(track.artistName)")
        .accessibilityHint("Plays this track")
        .accessibilityAddTraits(.isButton)
    }

    /// Start playback at this row, handing the surrounding list to
    /// `play(tracks:startIndex:)` so the rest of the section queues up.
    private func playFromHere() {
        guard let idx = queue.firstIndex(where: { $0.id == track.id }) else {
            model.play(tracks: [track], startIndex: 0)
            return
        }
        model.play(tracks: queue, startIndex: idx)
    }
}

// MARK: - Save sheet

/// Name-and-save sheet for the full-page queue. Functionally identical to
/// the inspector's `SaveQueueSheet`, kept private here so the full-page view
/// stays self-contained; both call `AppModel.saveQueueAsPlaylist(name:)`.
private struct FullQueueSaveSheet: View {
    @Binding var name: String
    let trackCount: Int
    let onCancel: () -> Void
    let onSave: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Save queue as playlist")
                    .font(Theme.font(15, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Text("Creates a new playlist with \(trackCount) \(trackCount == 1 ? "track" : "tracks").")
                    .font(Theme.font(11, weight: .medium))
                    .foregroundStyle(Theme.ink3)
            }

            TextField("Playlist name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(Theme.font(12, weight: .medium))
                .focused($focused)
                .onSubmit { onSave() }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { focused = true }
    }
}
