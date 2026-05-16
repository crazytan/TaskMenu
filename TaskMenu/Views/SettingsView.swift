import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Bindable var appState: AppState
    @State private var launchAtLogin = false
    @State private var isConfirmingDisconnect = false

    private let coffeeURL = URL(string: "https://buymeacoffee.com/crazytan")!
    private let discordURL = URL(string: "https://discord.gg/xEmdgGm7")!
    private let githubURL = URL(string: "https://github.com/crazytan/TaskMenu")!
    private let supportURL = URL(string: "https://taskmenu.crazytan.dev/support")!
    private let privacyURL = URL(string: "https://taskmenu.crazytan.dev/privacy")!

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            preferencesSection

            Divider()

            accountSection

            Divider()

            tipsSection

            Divider()

            supportSection

            Divider()

            aboutSection

            Divider()

            Button("Quit TaskMenu", role: .destructive) {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 2)
        }
        .font(.body)
        .padding(20)
        .frame(width: 360, alignment: .topLeading)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        .task {
            await appState.refreshGoogleAccountProfileIfNeeded()
        }
        .alert("Disconnect Google Account?", isPresented: $isConfirmingDisconnect) {
            Button("Cancel", role: .cancel) {}
            Button("Disconnect", role: .destructive) {
                disconnectGoogleAccount()
            }
        } message: {
            Text("TaskMenu will clear its stored Google credentials and remove local task data from this Mac.")
        }
    }

    private var preferencesSection: some View {
        SettingsSection("General") {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    setLaunchAtLogin(newValue)
                }

            Toggle("Due date notifications", isOn: $appState.dueDateNotificationsEnabled)
        }
    }

    private var accountSection: some View {
        SettingsSection("Account") {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(accountTitle)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button("Disconnect", role: .destructive) {
                    isConfirmingDisconnect = true
                }
                .disabled(!appState.isSignedIn)
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
    }

    private var tipsSection: some View {
        SettingsSection("Tips") {
            Text("TaskMenu will stay free forever and is developed by one person. If it saves you time, tips are deeply appreciated.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Link(destination: coffeeURL) {
                Label("Buy Me a Coffee", systemImage: "heart.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var supportSection: some View {
        SettingsSection("Support") {
            Text("Noticed a bug or have a feature request? Join our Discord server with the developer and other users!")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Link(destination: discordURL) {
                Label {
                    Text("Join Discord")
                } icon: {
                    Image("DiscordIcon")
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var aboutSection: some View {
        SettingsSection("About") {
            Text("TaskMenu v\(appVersion)")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Link(destination: githubURL) {
                    Label("GitHub", systemImage: "link")
                }

                Link(destination: supportURL) {
                    Label("Support", systemImage: "questionmark.circle")
                }

                Link(destination: privacyURL) {
                    Label("Privacy", systemImage: "lock")
                }
            }
            .font(.callout)
        }
    }

    private var accountTitle: String {
        guard appState.isSignedIn else { return "Not signed in" }
        return appState.googleAccountProfile?.displayEmail ?? "Google Account"
    }

    private func disconnectGoogleAccount() {
        Task {
            await appState.disconnectGoogleAccount()
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Silently fail — user can retry
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)

            content
        }
    }
}
