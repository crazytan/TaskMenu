import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Bindable var appState: AppState
    @State private var launchAtLogin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Settings")
                    .font(.headline)
                Spacer()
            }

            Divider()

            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    setLaunchAtLogin(newValue)
                }

            Divider()

            HStack {
                Text("TaskMenu v0.1.0")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Sign Out") {
                    appState.signOut()
                }
                .foregroundStyle(.red)
            }

            Button("Quit TaskMenu") {
                NSApplication.shared.terminate(nil)
            }
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
