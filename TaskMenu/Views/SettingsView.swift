import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Bindable var appState: AppState
    var onBack: () -> Void
    @State private var launchAtLogin = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with back button
            HStack {
                Button {
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderless)

                Text("Settings")
                    .font(.headline)
                Spacer()
            }

            Divider()

            // General
            Toggle("Launch at login", isOn: $launchAtLogin)
                .controlSize(.small)
                .onChange(of: launchAtLogin) { _, newValue in
                    setLaunchAtLogin(newValue)
                }

            Toggle("Global shortcut (Cmd+Shift+T)", isOn: $appState.globalShortcutEnabled)
                .controlSize(.small)

            Divider()

            // About
            Text("About")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            Text("TaskMenu v\(appVersion)")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Link(destination: URL(string: "https://github.com/crazytan/TaskMenu")!) {
                Label("GitHub", systemImage: "link")
            }
            .font(.caption)
            .controlSize(.small)

            Link(destination: URL(string: "https://github.com/crazytan/TaskMenu/issues/new")!) {
                Label("Report an Issue", systemImage: "exclamationmark.bubble")
            }
            .font(.caption)
            .controlSize(.small)

            // TODO: Replace with actual App Store link once published
            Text("Rate on App Store — coming soon")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Text("Tip the Developer — coming soon")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Divider()

            // Account & App
            Button("Sign Out") {
                withAnimation(.easeInOut(duration: 0.25)) {
                    appState.signOut()
                }
            }
            .controlSize(.small)
            .foregroundStyle(.red)

            Button("Quit TaskMenu") {
                NSApplication.shared.terminate(nil)
            }
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
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
