import SwiftUI

@MainActor
final class TaskMenuAppDelegate: NSObject, NSApplicationDelegate {
    lazy var appState: AppState = TaskMenuApp.makeAppState()

    private var statusBarController: StatusBarController?
    private let metricKitService = MetricKitService()
    private var uiTestingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !TaskMenuApp.isUnitTesting {
            metricKitService.start()
        }

        if TaskMenuApp.isUITesting {
            showUITestingWindow()
        } else if !TaskMenuApp.isUnitTesting {
            statusBarController = StatusBarController(appState: appState)
        }

        Task {
            await appState.bootstrapSignedInState()
        }
    }

    private func showUITestingWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "TaskMenu"
        window.contentViewController = NSHostingController(
            rootView: MenuBarPopover(appState: appState)
                .frame(width: 320, height: 480)
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        uiTestingWindow = window
    }
}

@main
struct TaskMenuApp: App {
    @NSApplicationDelegateAdaptor(TaskMenuAppDelegate.self) private var appDelegate

    static let isUITesting = CommandLine.arguments.contains("-ui-testing")
    static let isUnitTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    @MainActor
    static func makeAppState() -> AppState {
        if Self.isUITesting {
            // Make the app a regular app so UI automation can attach
            NSApplication.shared.setActivationPolicy(.regular)
            let mockAPI = MockTasksAPI()
            let state = AppState(api: mockAPI)
            state.isSignedIn = true
            return state
        }

        return AppState()
    }

    var body: some Scene {
        Settings {
            SettingsView(appState: appDelegate.appState)
        }
    }
}
