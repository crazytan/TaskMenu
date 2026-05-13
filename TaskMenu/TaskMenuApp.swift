import SwiftUI

@MainActor
final class TaskMenuAppDelegate: NSObject, NSApplicationDelegate {
    lazy var appState = AppState()

    private var statusBarController: StatusBarController?
    private let metricKitService = MetricKitService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !TaskMenuApp.isUnitTesting {
            metricKitService.start()
            statusBarController = StatusBarController(appState: appState)
        }

        Task {
            await appState.bootstrapSignedInState()
        }
    }
}

@main
struct TaskMenuApp: App {
    @NSApplicationDelegateAdaptor(TaskMenuAppDelegate.self) private var appDelegate

    static let isUnitTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    var body: some Scene {
        Settings {
            SettingsView(appState: appDelegate.appState)
        }
    }
}
