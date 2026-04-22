import AppKit
import SwiftUI

/// AppKit delegate for the SwiftUI app. Hosts platform plumbing that has no
/// first-class `Scene` equivalent:
///
/// - **Dock menu** (`applicationDockMenu`) — right-click / long-press on
///   the Dock icon surfaces Play/Pause, Next, Previous, and a live list
///   of recent albums so a user can jump back into something without
///   bringing the window forward. See issues #16 / #17.
/// - **Window tabbing** — opts the app into macOS' automatic window-tab
///   behaviour so `WindowGroup`'s extra windows show up as tabs under the
///   Window menu. See issue #27.
/// - **Sleep / wake hooks** — pauses playback when the system goes to
///   sleep and nudges the core to reconnect on wake so a discovered
///   server doesn't sit on a stale socket. See issue #323.
///
/// The delegate is wired in via `@NSApplicationDelegateAdaptor` from
/// `JellifyApp`. It publishes itself on `AppDelegate.shared` right after
/// `applicationDidFinishLaunching` so the SwiftUI side can hand over the
/// live `AppModel` pointer via `bind(appModel:)`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Weak shared pointer so views (that hold a strong reference to the
    /// `AppModel`) can drive the delegate without creating a retain cycle.
    static weak var shared: AppDelegate?

    /// The live app model. Injected from SwiftUI once the scene mounts —
    /// see `bind(appModel:)`. `nil` during the brief gap between
    /// `applicationDidFinishLaunching` and the first `WindowGroup` body
    /// evaluation; the menu / sleep / wake handlers degrade gracefully.
    private weak var appModel: AppModel?

    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // Window tabbing. With this set, `WindowGroup`'s New Window /
        // ⌘N produces a tab instead of a separate floating window on
        // screens that support tabbing. See #27.
        NSWindow.allowsAutomaticWindowTabbing = true

        // Sleep → pause. A laptop that closes its lid shouldn't keep
        // streaming through headphones after wake. See #323.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSleep()
        }

        // Wake → reconnect. Resume any network-bound work the core
        // needs to re-establish; the audio stream itself stays paused
        // so the user gets a clean resume.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWake()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let observer = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()

        let hasTrack = appModel?.status.currentTrack != nil
        let isPlaying = appModel?.status.state == .playing

        let playPauseItem = NSMenuItem(
            title: isPlaying ? "Pause" : "Play",
            action: #selector(dockTogglePlayPause(_:)),
            keyEquivalent: ""
        )
        playPauseItem.target = self
        playPauseItem.isEnabled = hasTrack
        menu.addItem(playPauseItem)

        let nextItem = NSMenuItem(
            title: "Next",
            action: #selector(dockSkipNext(_:)),
            keyEquivalent: ""
        )
        nextItem.target = self
        nextItem.isEnabled = hasTrack
        menu.addItem(nextItem)

        let previousItem = NSMenuItem(
            title: "Previous",
            action: #selector(dockSkipPrevious(_:)),
            keyEquivalent: ""
        )
        previousItem.target = self
        previousItem.isEnabled = hasTrack
        menu.addItem(previousItem)

        // Recent albums. Use `jumpBackIn` (the home screen's "last played"
        // shelf) as the source of truth so the dock menu and the window
        // stay in sync. Cap at six so the dock menu stays compact even
        // for heavy listeners.
        if let recent = appModel?.jumpBackIn, !recent.isEmpty {
            menu.addItem(NSMenuItem.separator())

            let header = NSMenuItem(title: "Recent Albums", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            for album in recent.prefix(6) {
                let item = NSMenuItem(
                    title: album.name,
                    action: #selector(dockPlayRecentAlbum(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = album.id
                item.toolTip = "\(album.name) — \(album.artistName)"
                menu.addItem(item)
            }
        }

        return menu
    }

    // MARK: - Binding

    /// Hand the delegate a live reference to the `AppModel`. Called once
    /// from the root SwiftUI view as soon as the scene mounts. Idempotent;
    /// re-binding replaces the previous pointer.
    @MainActor
    func bind(appModel: AppModel) {
        self.appModel = appModel
    }

    // MARK: - Sleep / wake

    private func handleSleep() {
        Task { @MainActor [weak self] in
            self?.appModel?.audio.pause()
        }
    }

    private func handleWake() {
        Task { @MainActor [weak self] in
            // Guarded nudge — today this is effectively a no-op when no
            // session exists, but it reserves the hook for #323's real
            // reconnect logic so future work can drop implementation in
            // without revisiting the AppKit side.
            self?.appModel?.reconnectIfNeeded()
        }
    }

    // MARK: - Dock menu actions

    @objc private func dockTogglePlayPause(_ sender: NSMenuItem) {
        Task { @MainActor [weak self] in
            self?.appModel?.togglePlayPause()
        }
    }

    @objc private func dockSkipNext(_ sender: NSMenuItem) {
        Task { @MainActor [weak self] in
            self?.appModel?.skipNext()
        }
    }

    @objc private func dockSkipPrevious(_ sender: NSMenuItem) {
        Task { @MainActor [weak self] in
            self?.appModel?.skipPrevious()
        }
    }

    @objc private func dockPlayRecentAlbum(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Task { @MainActor [weak self] in
            guard let model = self?.appModel else { return }
            if let album = model.jumpBackIn.first(where: { $0.id == id }) {
                model.play(album: album)
            }
        }
    }
}

// MARK: - AppModel sleep/wake shim

extension AppModel {
    /// Stub so the AppDelegate's wake hook has a call target today — a
    /// real reconnect implementation lands with the detailed network-health
    /// work in #323. Using a method here (rather than touching a closure)
    /// keeps the call site stable for that follow-up PR.
    ///
    /// Today this is a guarded no-op: if there's no session we have
    /// nothing to reconnect, and if there is, the existing network and
    /// reachability monitors will rediscover any broken route on their
    /// own polling cadence within a few seconds. The wake hook calls this
    /// anyway so the follow-up PR has a stable entry point to drop the
    /// real behaviour into.
    @objc func reconnectIfNeeded() {
        guard session != nil else { return }
        // TODO(#323): add an explicit post-sleep reconnect path — refresh
        // home shelves, reopen the media-session socket, and nudge the
        // core to re-validate the cached auth token against the server.
    }
}
