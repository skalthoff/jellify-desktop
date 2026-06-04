import AppKit

/// First-launch "move to Applications" helper — the LetsMove flow (#193).
///
/// When a user opens Lyrebird straight from the DMG (or from `~/Downloads`),
/// the app runs from a read-only / temporary location: Sparkle self-updates
/// can't write back into a mounted disk image, Gatekeeper App Translocation
/// hides the real path, and the icon never settles into the Dock. The clean
/// fix is the well-trodden LetsMove pattern: on the very first launch, if we
/// detect we're running from outside `/Applications`, offer to move ourselves
/// there and relaunch.
///
/// This type owns three concerns, deliberately split so the *decision* is
/// pure and unit-testable without a window server:
///
/// - `Environment` — a value snapshot of everything the decision depends on
///   (the bundle path, whether it's already installed, whether the path looks
///   translocated/quarantined, the build configuration, and the persisted
///   "don't ask again" flag). Captured from the live process in
///   `promptIfNeeded()`, or hand-built in tests.
/// - `shouldPrompt(_:)` — the pure rule. Given an `Environment`, returns
///   whether to surface the prompt. No side effects, no AppKit, no globals.
/// - `promptIfNeeded()` / `move(...)` — the runtime side: snapshot the
///   environment, run `shouldPrompt`, and on a yes show a native `NSAlert`
///   and perform the move + relaunch. These are the only parts that touch
///   `NSWorkspace`, the Dock, or `UserDefaults`.
///
/// Called once from `AppDelegate.applicationDidFinishLaunching`. Skipped
/// entirely in `DEBUG` so a `swift run` / Xcode debug session from
/// `.build/` or `DerivedData` never nags the developer.
enum MoveToApplications {
    /// Stable on-disk key for the "don't ask again" choice. Namespaced under
    /// `install.` alongside the other feature-scoped preference keys. Renaming
    /// it re-arms the prompt for every existing user, so it's pinned by tests.
    static let suppressKey = "install.suppressMoveToApplicationsPrompt"

    /// The canonical install root. A bundle whose path is anchored here (the
    /// user's `~/Applications` is intentionally *not* treated as installed —
    /// see `isInsideApplications`) needs no move.
    static let applicationsRoot = "/Applications"

    // MARK: - Decision inputs

    /// Immutable snapshot of everything `shouldPrompt(_:)` reasons about.
    /// Built from the live `Bundle` / `UserDefaults` in `promptIfNeeded()`;
    /// constructed directly in tests so the path-based rule can be exercised
    /// headlessly.
    struct Environment {
        /// Absolute filesystem path of the running `.app` bundle.
        var bundlePath: String

        /// Whether the bundle already lives under `/Applications`.
        var isInsideApplications: Bool

        /// Whether the bundle path looks like a Gatekeeper App Translocation
        /// mount, a still-mounted disk image, or a quarantined download.
        /// Moving is futile (translocated) or premature (the real copy hasn't
        /// landed yet) in these cases, so the prompt is suppressed — the user
        /// will get a clean shot once they drag the app out of the DMG.
        var isTranslocatedOrEphemeral: Bool

        /// True for `DEBUG` builds. The prompt never shows for developers
        /// running out of `.build/` or DerivedData.
        var isDebugBuild: Bool

        /// The persisted "don't ask again" choice.
        var userSuppressed: Bool
    }

    /// Pure first-launch decision: should we offer to move the app into
    /// `/Applications`?
    ///
    /// Returns `false` (no prompt) when any of the following hold, in order of
    /// precedence:
    /// - it's a `DEBUG` build,
    /// - the user previously chose "don't ask again",
    /// - the app is already installed under `/Applications`,
    /// - the path is translocated / on a mounted DMG / quarantined.
    ///
    /// Only a release build, running from a real on-disk location outside
    /// `/Applications`, with no prior suppression, yields `true`.
    ///
    /// Factored out of the AppKit flow so the path-based logic is verifiable
    /// without realizing an `NSAlert` (which a headless test run can't do).
    static func shouldPrompt(_ env: Environment) -> Bool {
        if env.isDebugBuild { return false }
        if env.userSuppressed { return false }
        if env.isInsideApplications { return false }
        if env.isTranslocatedOrEphemeral { return false }
        return true
    }

    // MARK: - Path classification (pure)

    /// Whether `path` is anchored under `/Applications`. A strict prefix match
    /// on the path *component* boundary so a sibling like
    /// `/ApplicationsArchive/Lyrebird.app` is not mistaken for an install, and
    /// the user-domain `~/Applications` (which Sparkle/Gatekeeper treat
    /// differently and which we still want to migrate to the system root)
    /// returns `false`.
    static func isInsideApplications(path: String) -> Bool {
        let root = applicationsRoot
        return path == root || path.hasPrefix(root + "/")
    }

    /// Heuristic for "this path is a translocation mount, a still-mounted disk
    /// image, or a quarantined download we shouldn't try to relocate yet".
    ///
    /// - **App Translocation**: Gatekeeper runs quarantined apps from a
    ///   randomized, read-only mount under
    ///   `/private/var/folders/.../AppTranslocation/`. The move is pointless
    ///   there — the bytes are a shadow copy.
    /// - **Mounted DMG**: a path under `/Volumes/` means the user double-
    ///   clicked the app inside the disk image. We don't move *out* of a DMG
    ///   (the source is read-only and the user expects to drag it themselves),
    ///   so we hold the prompt until they've copied it somewhere writable.
    static func isTranslocatedOrEphemeral(path: String) -> Bool {
        path.contains("/AppTranslocation/")
            || path.hasPrefix("/Volumes/")
            || path.contains("/.dmg/")
    }

    // MARK: - Runtime entry point

    /// Snapshot the live process environment and, if the rule says so, present
    /// the native move-to-Applications prompt. Safe to call unconditionally
    /// from `applicationDidFinishLaunching`; it self-gates via `shouldPrompt`.
    @MainActor
    static func promptIfNeeded(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard
    ) {
        let env = currentEnvironment(bundle: bundle, defaults: defaults)
        guard shouldPrompt(env) else { return }
        presentPrompt(bundlePath: env.bundlePath, defaults: defaults)
    }

    /// Build an `Environment` from the running process. `isDebugBuild` is
    /// resolved here (not in the pure rule) so the decision stays a value
    /// function the tests can drive across both configurations.
    static func currentEnvironment(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard
    ) -> Environment {
        let path = bundle.bundlePath
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        return Environment(
            bundlePath: path,
            isInsideApplications: isInsideApplications(path: path),
            isTranslocatedOrEphemeral: isTranslocatedOrEphemeral(path: path),
            isDebugBuild: debug,
            userSuppressed: defaults.bool(forKey: suppressKey)
        )
    }

    // MARK: - AppKit prompt + move

    /// Show the modal `NSAlert`. "Move to Applications Folder" performs the
    /// move + relaunch; "Do Not Move" dismisses for this launch; the
    /// "Don't ask again" checkbox persists the suppression flag regardless of
    /// which button is chosen.
    @MainActor
    private static func presentPrompt(bundlePath: String, defaults: UserDefaults) {
        let alert = NSAlert()
        alert.messageText = "Move Lyrebird to your Applications folder?"
        alert.informativeText = """
        Lyrebird works best from the Applications folder — it keeps automatic \
        updates working and prevents macOS from running it from a temporary \
        location. You can move it now and Lyrebird will reopen from there.
        """
        alert.alertStyle = .informational
        let moveButton = alert.addButton(withTitle: "Move to Applications Folder")
        moveButton.keyEquivalent = "\r"
        alert.addButton(withTitle: "Do Not Move")

        let suppress = NSButton(checkboxWithTitle: "Don't ask again", target: nil, action: nil)
        suppress.state = .off
        alert.accessoryView = suppress

        let response = alert.runModal()

        if suppress.state == .on {
            defaults.set(true, forKey: suppressKey)
        }

        guard response == .alertFirstButtonReturn else { return }

        move(fromBundlePath: bundlePath)
    }

    /// Move the running bundle into `/Applications` and relaunch from the new
    /// location, then terminate the current (old-location) instance.
    ///
    /// Uses `FileManager` for the copy/replace and `NSWorkspace` to relaunch.
    /// On any failure the move is abandoned and the app keeps running from its
    /// current location — a failed move must never strand the user without a
    /// running app. Errors surface in Console under the `app` category.
    @MainActor
    private static func move(fromBundlePath bundlePath: String) {
        let fileManager = FileManager.default
        let sourceURL = URL(fileURLWithPath: bundlePath)
        let appName = sourceURL.lastPathComponent
        let destURL = URL(fileURLWithPath: applicationsRoot).appendingPathComponent(appName)

        do {
            // Replace any stale copy already sitting at the destination
            // (e.g. an older version the user dragged over before) so the
            // copy below doesn't fail with "file exists".
            if fileManager.fileExists(atPath: destURL.path) {
                try fileManager.removeItem(at: destURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destURL)
        } catch {
            Log.app.error(
                "MoveToApplications copy failed: \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        // Relaunch from the installed copy, then quit this instance. The new
        // process opening is what lets us tear the old one down cleanly.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destURL, configuration: configuration) { _, error in
            if let error {
                Log.app.error(
                    "MoveToApplications relaunch failed: \(error.localizedDescription, privacy: .public)"
                )
                // The copy already succeeded; leaving the old instance running
                // is the safe fallback rather than terminating into nothing.
                return
            }
            DispatchQueue.main.async {
                // Best-effort cleanup of the old (source) copy once the new
                // instance is up. A failure here is cosmetic — the installed
                // copy is already running — so it's logged, not surfaced.
                try? fileManager.removeItem(at: sourceURL)
                NSApp.terminate(nil)
            }
        }
    }
}
