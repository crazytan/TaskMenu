import AppKit

@MainActor
enum TaskMenuApp {
    static let isUnitTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}

@main
@MainActor
enum TaskMenuApplication {
    private(set) static var installedDelegate: TaskMenuAppDelegate?

    static func main() {
        let application = NSApplication.shared
        let delegate = TaskMenuAppDelegate()
        installedDelegate = delegate
        application.delegate = delegate
        application.run()
    }
}

@MainActor
final class TaskMenuAppDelegate: NSObject, NSApplicationDelegate {
    lazy var appState = AppState()

    private var statusBarController: StatusBarController?
    private var settingsWindowController: SettingsWindowController?
    private let metricKitService = MetricKitService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !TaskMenuApp.isUnitTesting {
            metricKitService.start()
            statusBarController = StatusBarController(appState: appState)
            startAutomaticUpdateCheck()
        }

        Task {
            await appState.bootstrapSignedInState()
        }
    }

    private func startAutomaticUpdateCheck() {
        Task { [weak self] in
            guard let self,
                  let release = await appState.checkForUpdatesIfNeeded() else {
                return
            }

            presentUpdateAlert(for: release)
        }
    }

    private func presentUpdateAlert(for release: AppUpdateRelease) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "TaskMenu \(release.version) is available"
        alert.informativeText = "You are using TaskMenu \(appState.currentAppVersion). Download the latest release from GitHub?"
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")

        NSApplication.shared.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        appState.markUpdateAlertShown(for: release)

        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.releaseURL)
        }
    }

    @objc func showSettingsWindow(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(appState: appState)
        }

        settingsWindowController?.showSettings()
    }
}
