import SwiftUI
@preconcurrency import JellifyCore

/// Right-side "Queue Inspector" panel (320pt) that surfaces the currently-
/// playing track, the user-added "Up Next" list, and the auto-queue tail.
///
/// Implements issues #79 (the panel itself), #80 (drag-to-reorder + remove),
/// and #282 (Up Next vs Auto Queue separation).
///
/// Layout (top → bottom):
///   1. **Now Playing card** — large thumbnail, title/artist/album, and a
///      read-only scrubber driven by `AppModel.status.positionSeconds`.
///   2. **UP NEXT** — user-added queue; drag-reorder via `.onMove`,
///      per-row X button on hover, keyboard reorder via Opt+↑/Opt+↓.
///   3. **PLAYING FROM {source}** — auto-queue tail; double-click jumps
///      to that track.
///
/// The panel is mounted by `MainShell` via `appModel.isQueueInspectorOpen`
/// and toggled with Cmd+Opt+Q. The visible toggle in the PlayerBar will
/// land in BATCH-07b alongside #82 / #283 / #284.
struct QueueInspector: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focusedQueueId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    nowPlayingCard
                    upNextSection
                    playingFromSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Theme.bgAlt)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack {
            Text("Queue")
                .font(Theme.font(11, weight: .bold))
                .foregroundStyle(Theme.ink2)
                .tracking(2)
                .textCase(.uppercase)
            Spacer()
            // Note: the Cmd+Opt+Q toggle lives on `MainShell` so it works
            // whether the panel is open or closed. The X here is click-only
            // so we don't register two responders for the same shortcut.
            Button(action: { model.isQueueInspectorOpen = false }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Theme.surface))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close queue")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    // MARK: - Now Playing card

    @ViewBuilder
    private var nowPlayingCard: some View {
        if let track = model.status.currentTrack {
            VStack(alignment: .leading, spacing: 12) {
                Artwork(
                    url: model.imageURL(
                        for: track.albumId ?? track.id,
                        tag: track.imageTag,
                        maxWidth: 480
                    ),
                    seed: track.name,
                    size: 288,
                    radius: 10
                )
                .frame(width: 288, height: 288)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.name)
                        .font(Theme.font(17, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                    Text(track.artistName)
                        .font(Theme.font(12, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                    if let album = track.albumName, !album.isEmpty {
                        Text(album)
                            .font(Theme.font(11, weight: .medium))
                            .foregroundStyle(Theme.ink3)
                            .lineLimit(1)
                    }
                }
                scrubber
            }
        } else {
            EmptyQueueState()
                .frame(height: 320)
        }
    }

    /// Read-only scrubber. The real seek control lives in the PlayerBar;
    /// here we mirror playback progress so the inspector reads as a live
    /// widget rather than a static list. Driven by
    /// `AppModel.status.positionSeconds` / `durationSeconds`, which are
    /// pushed from the polling loop (#48).
    @ViewBuilder
    private var scrubber: some View {
        VStack(spacing: 4) {
            GeometryReader { geom in
                let total = max(1.0, model.status.durationSeconds)
                let pct = min(1.0, max(0.0, model.status.positionSeconds / total))
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surface2)
                    Capsule().fill(Theme.ink2).frame(width: geom.size.width * CGFloat(pct))
                }
                .frame(height: 3)
            }
            .frame(height: 3)
            HStack {
                Text(format(model.status.positionSeconds))
                    .font(Theme.font(10, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
                    .monospacedDigit()
                Spacer()
                Text(format(model.status.durationSeconds))
                    .font(Theme.font(10, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Up Next (user-added)

    @ViewBuilder
    private var upNextSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Up Next")
            if model.upNextUserAdded.isEmpty {
                emptyRow("Nothing queued. Use \u{2318}-click \u{2192} Play Next on a track.")
            } else {
                // `List` is the only SwiftUI primitive that exposes `.onMove`
                // wiring for drag-to-reorder — see #80. `height` is bounded
                // to a generous cap so the panel doesn't grow unbounded on
                // very long queues; past the cap the list scrolls internally.
                List {
                    ForEach(model.upNextUserAdded) { entry in
                        QueueInspectorRow(
                            entry: entry,
                            removable: true,
                            onRemove: { model.removeFromUpNext(id: entry.id) },
                            onMoveUp: { moveEntry(entry, by: -1) },
                            onMoveDown: { moveEntry(entry, by: 1) }
                        )
                        .focused($focusedQueueId, equals: entry.id)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                    }
                    .onMove { indexSet, newOffset in
                        model.moveUpNext(from: indexSet, to: newOffset)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(height: boundedListHeight(for: model.upNextUserAdded.count))
            }
        }
    }

    // MARK: - Playing From (auto queue)

    @ViewBuilder
    private var playingFromSection: some View {
        if !model.upNextAutoQueue.isEmpty || model.currentContext != nil {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader(playingFromHeaderTitle)
                if model.upNextAutoQueue.isEmpty {
                    emptyRow("Nothing else queued from this source.")
                } else {
                    // Simple `ForEach` here — no drag-reorder on the auto
                    // tail (it's the source's natural order; reordering
                    // would be #282's next step, post-core primitive).
                    VStack(spacing: 0) {
                        ForEach(model.upNextAutoQueue) { entry in
                            QueueInspectorRow(
                                entry: entry,
                                removable: false,
                                onRemove: {},
                                onMoveUp: {},
                                onMoveDown: {}
                            )
                            .onTapGesture(count: 2) { jumpTo(entry: entry) }
                        }
                    }
                }
            }
        }
    }

    /// Section title for the "Playing From" block. Prefers the live
    /// context label when present and falls back to a generic string so
    /// the block still reads clearly on ad-hoc selections.
    private var playingFromHeaderTitle: String {
        if let name = model.currentContext?.name, !name.isEmpty {
            return "Playing From \(name)"
        }
        return "Playing From Queue"
    }

    // MARK: - Actions

    /// Shift `entry` within the user-added list by `delta` rows (clamped).
    /// Wired to Opt+↑ / Opt+↓ on a focused row so reorder is usable from
    /// the keyboard as well as the mouse. See #80.
    private func moveEntry(_ entry: Queue, by delta: Int) {
        guard let idx = model.upNextUserAdded.firstIndex(where: { $0.id == entry.id }) else { return }
        let target = idx + delta
        guard target >= 0, target < model.upNextUserAdded.count else { return }
        // `List.onMove`'s `toOffset` semantics are "insert before this
        // index after the item has been removed", so we bias the offset
        // when moving down to land in the expected slot.
        let offset = delta > 0 ? target + 1 : target
        model.moveUpNext(from: IndexSet(integer: idx), to: offset)
    }

    /// Jump playback to an auto-queue entry. Implementation is deliberately
    /// a no-op stub for BATCH-07a: the underlying "seek to queue index"
    /// primitive (TODO(core-#282)) does not exist yet. Double-clicking a
    /// row still triggers this handler so the interaction is wired and
    /// BATCH-07b / core can land the playback side without touching the UI.
    private func jumpTo(entry: Queue) {
        // TODO(core-#282): needs `seek_to_queue_index` on the Rust player.
        // Until then, surface a log so manual QA knows the row registered.
        print("[QueueInspector] jumpTo(\(entry.track.name)) needs core seek primitive — see #282")
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Theme.font(10, weight: .bold))
            .foregroundStyle(Theme.ink2)
            .tracking(1.5)
            .textCase(.uppercase)
    }

    @ViewBuilder
    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(Theme.font(11, weight: .medium))
            .foregroundStyle(Theme.ink3)
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func format(_ seconds: Double) -> String {
        let safe = seconds.isFinite ? max(0, seconds) : 0
        let total = Int(safe)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    /// Cap the reorder list height so a 200-track user queue can't push
    /// the rest of the inspector off-screen. Each row is ~44pt tall; we
    /// ceiling at 8 rows, past which the list scrolls internally.
    private func boundedListHeight(for rows: Int) -> CGFloat {
        let rowHeight: CGFloat = 44
        let visible = min(max(rows, 1), 8)
        return CGFloat(visible) * rowHeight
    }
}

// MARK: - Row

/// One track row in the Queue Inspector. Shared between the user-added
/// "Up Next" list and the auto-queue tail — the only behavioural knob is
/// `removable`, which toggles the trailing X button on hover. Keyboard
/// reorder (Opt+↑/↓) is plumbed through `onMoveUp` / `onMoveDown`; the
/// callbacks are no-ops for rows that aren't reorderable.
private struct QueueInspectorRow: View {
    @Environment(AppModel.self) private var model
    let entry: Queue
    let removable: Bool
    let onRemove: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Artwork(
                url: model.imageURL(
                    for: entry.track.albumId ?? entry.track.id,
                    tag: entry.track.imageTag,
                    maxWidth: 120
                ),
                seed: entry.track.albumName ?? entry.track.name,
                size: 32,
                radius: 4
            )
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.track.name)
                    .font(Theme.font(12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(entry.track.artistName)
                    .font(Theme.font(10, weight: .medium))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)

            if removable, isHovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.ink2)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Theme.surface))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(entry.track.name) from Up Next")
                .transition(.opacity)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Theme.rowHover : .clear)
        )
        .contentShape(Rectangle())
        .focusable(removable)
        // Opt+↑ / Opt+↓ reorders the focused row. Only match when the
        // Option modifier is held so plain arrow keys fall through to
        // the surrounding list's focus traversal.
        .onKeyPress(phases: .down) { press in
            guard press.modifiers.contains(.option) else { return .ignored }
            switch press.key {
            case .upArrow:
                onMoveUp()
                return .handled
            case .downArrow:
                onMoveDown()
                return .handled
            default:
                return .ignored
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .accessibilityLabel("\(entry.track.name) by \(entry.track.artistName)")
    }
}
