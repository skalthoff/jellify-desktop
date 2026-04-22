import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var model

    @State private var url: String = ""
    @State private var username: String = ""
    @State private var password: String = ""

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 24) {
                VStack(spacing: 4) {
                    Text("Jellify")
                        .font(Theme.font(40, weight: .black, italic: true))
                        .foregroundStyle(Theme.ink)
                    Text("DESKTOP")
                        .font(Theme.font(10, weight: .bold))
                        .foregroundStyle(Theme.ink3)
                        .tracking(3)
                }
                .padding(.bottom, 8)

                VStack(alignment: .leading, spacing: 14) {
                    field("Server URL", text: $url, placeholder: "https://jellyfin.example.com")
                    field("Username", text: $username, placeholder: "you")
                    field("Password", text: $password, placeholder: "••••••••", secure: true)

                    if let error = model.errorMessage {
                        Text(error)
                            .font(Theme.font(12, weight: .medium))
                            .foregroundStyle(Theme.accentHot)
                            .padding(.top, 4)
                    }
                }
                .frame(width: 340)

                Button {
                    Task { await model.login(url: url, username: username, password: password) }
                } label: {
                    HStack(spacing: 8) {
                        if model.isLoggingIn {
                            ProgressView().scaleEffect(0.7).tint(Theme.bg)
                        }
                        Text(model.isLoggingIn ? "Signing in…" : "Sign in")
                            .font(Theme.font(14, weight: .bold))
                    }
                    .frame(width: 340, height: 42)
                    .foregroundStyle(Theme.bg)
                    .background(Theme.ink)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                }
                .buttonStyle(.plain)
                .disabled(model.isLoggingIn || url.isEmpty || username.isEmpty)
                .opacity(url.isEmpty || username.isEmpty ? 0.5 : 1)
            }
            .padding(40)
        }
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, placeholder: String, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(Theme.font(10, weight: .bold))
                .foregroundStyle(Theme.ink3)
                .tracking(1.5)
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textFieldStyle(.plain)
            .font(Theme.font(14, weight: .medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Theme.border, lineWidth: 1)
            )
        }
    }
}
