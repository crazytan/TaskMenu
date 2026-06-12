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

    static var shouldSeedTestingWindowTasks: Bool {
        shouldSeedTestingWindowTasks(arguments: CommandLine.arguments)
    }

    static func uiMode(arguments: [String]) -> TaskMenuUIMode {
        if arguments.contains("--testing-window") {
            return .testingWindow
        }

        return .menuBar
    }

    static func shouldSeedTestingWindowTasks(arguments: [String]) -> Bool {
        arguments.contains("--testing-window") && arguments.contains("--seeded-tasks")
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
    lazy var appState: AppState = {
        if TaskMenuApp.shouldSeedTestingWindowTasks {
            let state = AppState(api: TestingWindowTasksAPI())
            state.isSignedIn = true
            return state
        }

        return AppState()
    }()

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

private actor TestingWindowTasksAPI: TasksAPIProtocol {
    private let list = TaskList(id: "seeded-list", title: "Seeded Tasks", selfLink: nil, updated: nil)
    private var tasks: [TaskItem] = [
        TaskItem(
            id: "active-parent",
            title: "Active parent with subtasks",
            notes: nil,
            status: .needsAction,
            due: nil,
            selfLink: nil,
            parent: nil,
            position: "0001",
            updated: nil
        ),
        TaskItem(
            id: "active-child",
            title: "Active subtask aligned left",
            notes: nil,
            status: .needsAction,
            due: nil,
            selfLink: nil,
            parent: "active-parent",
            position: "0001",
            updated: nil
        ),
        TaskItem(
            id: "delete-target",
            title: "Right click delete target",
            notes: nil,
            status: .needsAction,
            due: nil,
            selfLink: nil,
            parent: nil,
            position: "0002",
            updated: nil
        ),
        TaskItem(
            id: "active-standalone",
            title: "Another active task",
            notes: nil,
            status: .needsAction,
            due: nil,
            selfLink: nil,
            parent: nil,
            position: "0003",
            updated: nil
        ),
        TaskItem(
            id: "completed-root",
            title: "Completed root task",
            notes: nil,
            status: .completed,
            due: nil,
            selfLink: nil,
            parent: nil,
            position: "0004",
            updated: nil
        ),
        TaskItem(
            id: "completed-child",
            title: "Completed subtask aligned left",
            notes: nil,
            status: .completed,
            due: nil,
            selfLink: nil,
            parent: "active-parent",
            position: "0002",
            updated: nil
        )
    ]

    func listTaskLists() async throws -> [TaskList] {
        [list]
    }

    func listTasks(listId: String, showCompleted: Bool, showHidden: Bool) async throws -> [TaskItem] {
        showCompleted ? tasks : tasks.filter { !$0.isCompleted }
    }

    func createTask(listId: String, title: String, notes: String?, due: String?, parentId: String?) async throws -> TaskItem {
        let task = TaskItem(
            id: UUID().uuidString,
            title: title,
            notes: notes,
            status: .needsAction,
            due: due,
            selfLink: nil,
            parent: parentId,
            position: String(format: "%04d", tasks.count + 1),
            updated: nil
        )
        tasks.insert(task, at: 0)
        return task
    }

    func updateTask(listId: String, taskId: String, task: TaskItem) async throws -> TaskItem {
        if let index = tasks.firstIndex(where: { $0.id == taskId }) {
            tasks[index] = task
        }
        return task
    }

    func deleteTask(listId: String, taskId: String) async throws {
        let childIDs = tasks.filter { $0.parent == taskId }.map(\.id)
        let removedIDs = Set([taskId] + childIDs)
        tasks.removeAll { removedIDs.contains($0.id) }
    }

    func moveTask(listId: String, taskId: String, previousId: String?, parentId: String?) async throws -> TaskItem {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else {
            throw APIError.serverError(404, "Task not found")
        }
        tasks[index].parent = parentId
        return tasks[index]
    }
}
