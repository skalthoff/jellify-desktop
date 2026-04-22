import AppKit
import SwiftUI

/// The "Account" pane of the Preferences window. Shows the signed-in server
/// URL and username, and offers "Change server…" and "Sign out" actions.
///
/// Both actions hang off the existing `AppModel.forgetToken()` entry point
/// (added for the auth-expired flow in #303) — they drop the stored token and
/// null the session so `RootView` routes back to `LoginView`. The difference
/// is cosmetic: "Sign out" leaves the remembered server URL + username on the
/// model so the user re-enters only their password, while "Change server…"
/// also clears those so the login form comes up blank.
///
/// Issue: #259.
struct PreferencesAccount: View {
    @Environment(AppModel.self) private var model

    @State private var confirmChangeServer: Bool = false
    @State private var confirmSignOut: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            VStack(alignment: .leading, spacing: 14) {
                field(
                    label: "Server",
                    value: model.serverURL.isEmpty ? "—" : model.serverURL,
                    accessibilityLabel: "Server URL"
                )
                field(
                    label: "Username",
                    value: model.username.isEmpty ? "—" : model.username,
                    accessibilityLabel: "Signed-in username"
                )
            }

            actions

            Spacer(minLength: 0)
        }
        .alert("Change server?", isPresented: $confirmChangeServer) {
            Button("Cancel", role: .cancel) {}
            Button("Change server", role: .destructive) { changeServer() }
        } message: {
            Text("You'll be signed out and returned to the login screen so you can connect to a different Jellyfin server.")
        }
        .alert("Sign out?", isPresented: $confirmSignOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign out", role: .destructive) { signOut() }
        } message: {
            Text("You'll be signed out of \(displayServer). Your server URL and username are remembered so you can sign back in with just your password.")
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Account")
                .font(Theme.font(28, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)
            Text("Signed-in server and user.")
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink3)
        }
    }

    @ViewBuilder
    private func field(label: String, value: String, accessibilityLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(Theme.font(10, weight: .bold))
                .foregroundStyle(Theme.ink3)
                .tracking(1.5)
            Text(value)
                .font(Theme.font(14, weight: .medium))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.border, lineWidth: 1)
                )
        }
        .frame(maxWidth: 420, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(accessibilityLabel): \(value)")
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                confirmChangeServer = true
            } label: {
                Text("Change server…")
                    .font(Theme.font(13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Theme.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.border, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Change server")
            .accessibilityHint("Signs out and returns to the login screen to connect to a different server.")

            Button {
                confirmSignOut = true
            } label: {
                Text("Sign out")
                    .font(Theme.font(13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sign out")
            .accessibilityHint("Signs out of the current server.")
        }
    }

    // MARK: - Actions

    /// Drop the stored token, null the session, and leave the server URL /
    /// username on the model. `RootView` will route back to `LoginView`,
    /// which prefills those so the user only re-enters their password.
    private func signOut() {
        model.forgetToken()
        model.session = nil
        // Clear the auth-expired flag so an ambient 401 prompt doesn't
        // re-appear on top of the login screen after a manual sign-out.
        model.authExpired = false
        closePreferencesWindow()
    }

    /// Sign out AND clear the remembered server URL + username so the login
    /// form comes up empty, ready for a different server.
    private func changeServer() {
        model.forgetToken()
        model.session = nil
        model.serverURL = ""
        model.username = ""
        model.authExpired = false
        closePreferencesWindow()
    }

    /// String used in the Sign-out confirmation body. Falls back to the
    /// generic "this server" wording if we somehow don't have a URL.
    private var displayServer: String {
        model.serverURL.isEmpty ? "this server" : model.serverURL
    }

    /// Close the Preferences window after signing out — otherwise it sits on
    /// top of LoginView, which is jarring. The Settings scene owns a single
    /// window; closing the key window is enough.
    private func closePreferencesWindow() {
        // Running on the next runloop tick gives SwiftUI a chance to commit
        // the session=nil state change first, so the user sees Login under
        // the (closing) Preferences window rather than a brief flash of
        // MainShell.
        DispatchQueue.main.async {
            NSApplication.shared.keyWindow?.performClose(nil)
        }
    }
}

#Preview {
    // Note: real rendering requires an `AppModel` in the environment; the
    // Settings scene in `JellifyApp` injects one. Previews without a model
    // will crash on `@Environment(AppModel.self)` — this preview is kept as
    // documentation for where the view lives.
    PreferencesAccount()
        .frame(width: 560, height: 400)
        .background(Theme.bg)
}
