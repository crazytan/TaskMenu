import AppKit

enum TaskMenuUIMode: Equatable {
    case menuBar
    case testingWindow
}

@MainActor
enum TaskMenuApp {
    static let isUnitTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static var currentUIMode: TaskMenuUIMode {
        uiMode(arguments: CommandLine.arguments)
    }

    static func uiMode(arguments: [String]) -> TaskMenuUIMode {
        if arguments.contains("--testing-window") {
            return .testingWindow
        }

        return .menuBar
    }
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
    private var testingWindowController: TestingWindowController?
    private var settingsWindowController: SettingsWindowController?
    private let metricKitService = MetricKitService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if TaskMenuApp.currentUIMode == .testingWindow || !TaskMenuApp.isUnitTesting {
            configureUserInterface(for: TaskMenuApp.currentUIMode)
        }

        Task {
            await appState.bootstrapSignedInState()
        }
    }

    private func configureUserInterface(for uiMode: TaskMenuUIMode) {
        switch uiMode {
        case .menuBar:
            metricKitService.start()
            statusBarController = StatusBarController(appState: appState)
            startAutomaticUpdateCheck()
        case .testingWindow:
            _ = NSApp.setActivationPolicy(.regular)
            testingWindowController = TestingWindowController(appState: appState)
            testingWindowController?.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
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
