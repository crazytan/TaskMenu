import AppKit

enum TaskMenuUIMode: Equatable {
    case menuBar
    case testingWindow
}

/// User response to the update-available alert. "Later" only defers until the
/// next due automatic check (nothing is persisted); "Download" and
/// "Skip This Version" persist the version so it is not alerted again.
enum UpdateAlertChoice: Equatable, Sendable {
    case download
    case later
    case skipThisVersion

    init(modalResponse: NSApplication.ModalResponse) {
        switch modalResponse {
        case .alertFirstButtonReturn:
            self = .download
        case .alertThirdButtonReturn:
            self = .skipThisVersion
        default:
            self = .later
        }
    }

    var persistsAlertedVersion: Bool {
        self != .later
    }

    var opensReleasePage: Bool {
        self == .download
    }
}

@MainActor
enum TaskMenuApp {
    static let isUnitTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static var currentUIMode: TaskMenuUIMode {
        uiMode(arguments: CommandLine.arguments)
    }

    /// Screen a `--testing-window --demo` launch opens on its own, so App
    /// Store preview sources can be recaptured identically each release
    /// instead of being clicked through by hand.
    enum CaptureScreen: String {
        case list
        case task
        case settings
    }

    static var captureScreen: CaptureScreen? {
        captureScreen(arguments: CommandLine.arguments)
    }

    /// Prints the identity `AppStorePreviews/capture_sources.py` needs to grab
    /// exactly this window: `screencapture -l<number>` plus the title-bar
    /// height to crop off, in backing pixels.
    /// Moves a capture window onto the sharpest attached display. Without
    /// this the shot follows whichever screen the window happened to open on,
    /// and a 1x display silently yields half-resolution screenshots.
    static func centerOnSharpestScreen(_ window: NSWindow) {
        guard let screen = NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor })
        else {
            return
        }

        let visible = screen.visibleFrame
        let frame = window.frame
        window.setFrameOrigin(
            NSPoint(
                x: visible.midX - frame.width / 2,
                y: visible.midY - frame.height / 2
            )
        )
    }

    static func printCaptureWindowDescriptor(for window: NSWindow) {
        let scale = window.backingScaleFactor
        let titleBarPoints = window.frame.height - window.contentLayoutRect.height
        print(
            "CAPTURE window=\(window.windowNumber)"
                + " titlebar=\(Int((titleBarPoints * scale).rounded()))"
                + " scale=\(Int(scale))"
                + " width=\(Int(window.frame.width))"
        )
        fflush(stdout)
    }

    static func captureScreen(arguments: [String]) -> CaptureScreen? {
        guard let flagIndex = arguments.firstIndex(of: "--capture"),
              arguments.indices.contains(flagIndex + 1)
        else {
            return nil
        }

        return CaptureScreen(rawValue: arguments[flagIndex + 1])
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
    lazy var appState: AppState = {
        if TaskMenuApp.currentUIMode == .testingWindow {
            return Self.makeTestingWindowAppState()
        }

        return AppState()
    }()

    /// Builds a fully in-memory `AppState` for `--testing-window` launches:
    /// fake seeded tasks, no Keychain access, no Google credentials, no
    /// notifications, no update checks, and throwaway UserDefaults.
    ///
    /// Adding `--signed-out` starts on the sign-in screen instead, which is
    /// how the demo-mode entry point gets exercised without credentials.
    /// Adding `--demo` skips straight into demo mode.
    /// Adding `--capture` renders the App Store preview states: the same
    /// realistic sample data, but signed in, so no demo banner or demo account
    /// row appears in the marketing screenshots.
    private static func makeTestingWindowAppState() -> AppState {
        let suiteName = "TaskMenu.TestingWindow"
        let userDefaults = UserDefaults(suiteName: suiteName) ?? .standard
        userDefaults.removePersistentDomain(forName: suiteName)

        let isCapture = TaskMenuApp.captureScreen != nil
        let state = AppState(
            authService: GoogleAuthService(keychain: InMemoryKeychainService()),
            api: isCapture ? DemoTasksAPI() : TestingWindowTasksAPI(),
            userDefaults: userDefaults,
            dueDateNotificationService: NoOpDueDateNotificationService(),
            updateChecker: DisabledUpdateChecker()
        )
        guard !CommandLine.arguments.contains("--signed-out") else { return state }

        if !isCapture, CommandLine.arguments.contains("--demo") {
            state.enterDemoMode()
            return state
        }

        state.isSignedIn = true
        state.googleAccountProfile = GoogleAccountProfile(
            email: isCapture ? "you@example.com" : "testing-window@example.com"
        )
        return state
    }

    private var statusBarController: StatusBarController?
    private var testingWindowController: TestingWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var automaticUpdateCheckTask: Task<Void, Never>?
    private let metricKitService = MetricKitService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Install before any UI. The main menu is what routes Cut/Copy/Paste/
        // Select All/Undo to the first responder, and every UI mode needs it:
        // popover text fields, the Settings window, and --testing-window.
        TaskMenuMainMenu.install(into: NSApplication.shared)

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
            if TaskMenuApp.captureScreen == .settings {
                showSettingsWindow(nil)
            }
            if TaskMenuApp.captureScreen != nil {
                let captureWindow = TaskMenuApp.captureScreen == .settings
                    ? settingsWindowController?.window
                    : testingWindowController?.window
                if let captureWindow {
                    TaskMenuApp.centerOnSharpestScreen(captureWindow)
                    TaskMenuApp.printCaptureWindowDescriptor(for: captureWindow)
                }
            }
        }
    }

    private func startAutomaticUpdateCheck() {
        let interval = appState.updateCheckInterval
        automaticUpdateCheckTask = Task { [weak self] in
            await TaskMenuAppDelegate.runAutomaticUpdateChecks(
                checkForUpdates: { [weak self] in
                    guard let self else { return nil }
                    return await self.appState.checkForUpdatesIfNeeded()
                },
                presentAlert: { [weak self] release in
                    self?.presentUpdateAlert(for: release)
                },
                sleepBetweenChecks: {
                    try await Task.sleep(for: .seconds(interval))
                }
            )
        }
    }

    /// Long-lived automatic check loop for the resident menu-bar app: check at
    /// launch, then re-check each time the sleep interval elapses.
    /// `checkForUpdatesIfNeeded` already gates on the user preference and the
    /// 24-hour due window, so the loop can unconditionally call it. The loop
    /// ends when its `Task` is cancelled or the sleep throws.
    static func runAutomaticUpdateChecks(
        checkForUpdates: @MainActor () async -> AppUpdateRelease?,
        presentAlert: @MainActor (AppUpdateRelease) -> Void,
        sleepBetweenChecks: @MainActor () async throws -> Void
    ) async {
        while !Task.isCancelled {
            if let release = await checkForUpdates() {
                presentAlert(release)
            }

            do {
                try await sleepBetweenChecks()
            } catch {
                return
            }
        }
    }

    private func presentUpdateAlert(for release: AppUpdateRelease) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "TaskMenu \(release.version) is available"
        alert.informativeText = "You are using TaskMenu \(appState.currentAppVersion). Download the latest release from GitHub?"
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")

        NSApplication.shared.activate(ignoringOtherApps: true)
        let choice = UpdateAlertChoice(modalResponse: alert.runModal())

        // "Later" leaves the version eligible so the next due automatic check
        // re-alerts; the other choices persist it as seen.
        if choice.persistsAlertedVersion {
            appState.markUpdateAlertShown(for: release)
        }

        if choice.opensReleasePage {
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

/// Keychain stand-in for testing-window launches; data lives and dies with the process.
private final class InMemoryKeychainService: KeychainServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func save(key: String, data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = data
    }

    func save(key: String, string: String) throws {
        try save(key: key, data: Data(string.utf8))
    }

    func read(key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func readString(key: String) throws -> String? {
        guard let data = try read(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = nil
    }

    func deleteAll() throws {
        lock.lock()
        defer { lock.unlock() }
        storage = [:]
    }
}

private struct NoOpDueDateNotificationService: DueDateNotificationServicing {
    func syncNotifications(for tasks: [TaskItem], in list: TaskList) async {}
    func removeNotifications(forTaskIDs taskIDs: [String], inListID listID: String) async {}
    func removeAllNotifications() async {}
}

private struct DisabledUpdateChecker: UpdateChecking {
    func latestUpdate(currentVersion: String) async throws -> AppUpdateRelease? {
        nil
    }
}

private actor TestingWindowTasksAPI: TasksAPIProtocol {
    private let lists = [
        TaskList(id: "seeded-list", title: "Seeded Tasks", selfLink: nil, updated: nil),
        TaskList(id: "seeded-due-dates", title: "Due Dates", selfLink: nil, updated: nil),
        TaskList(id: "seeded-long-subtasks", title: "Long Subtasks", selfLink: nil, updated: nil),
        TaskList(id: "seeded-empty", title: "Empty List", selfLink: nil, updated: nil)
    ]
    private var tasksByListID: [String: [TaskItem]]

    init() {
        func dueString(daysFromToday offset: Int) -> String? {
            guard let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) else { return nil }
            return DateFormatting.formatGoogleTaskDueDate(date)
        }

        func task(
            _ id: String,
            _ title: String,
            status: TaskItem.TaskStatus = .needsAction,
            dueInDays: Int? = nil,
            parent: String? = nil,
            position: String
        ) -> TaskItem {
            TaskItem(
                id: id,
                title: title,
                notes: nil,
                status: status,
                due: dueInDays.flatMap { dueString(daysFromToday: $0) },
                selfLink: nil,
                parent: parent,
                position: position,
                updated: nil
            )
        }

        let longSubtasks = (1...12).map { index in
            task(
                String(format: "long-child-%02d", index),
                String(format: "Long edit subtask %02d", index),
                status: index >= 9 ? .completed : .needsAction,
                parent: "long-parent",
                position: String(format: "%04d", index)
            )
        }

        tasksByListID = [
            "seeded-list": [
                task("active-parent", "Active parent with subtasks", position: "0001"),
                task("active-child", "Active subtask aligned left", parent: "active-parent", position: "0001"),
                task("delete-target", "Right click delete target", position: "0002"),
                task("active-standalone", "Another active task", position: "0003"),
                task("completed-root", "Completed root task", status: .completed, position: "0004"),
                task("completed-child", "Completed subtask aligned left", status: .completed, parent: "active-parent", position: "0002")
            ],
            "seeded-due-dates": [
                task("due-parent", "Parent due tomorrow with dated subtasks", dueInDays: 1, position: "0001"),
                task("due-child-today", "Subtask due today", dueInDays: 0, parent: "due-parent", position: "0001"),
                task("due-child-overdue", "Subtask overdue by two days", dueInDays: -2, parent: "due-parent", position: "0002"),
                task("due-child-completed", "Completed subtask due yesterday", status: .completed, dueInDays: -1, parent: "due-parent", position: "0003"),
                task("due-overdue", "Standalone overdue by a week", dueInDays: -7, position: "0002"),
                task("due-future", "Standalone due in two weeks", dueInDays: 14, position: "0003"),
                task("due-none", "Standalone without a due date", position: "0004"),
                task("due-completed-root", "Completed root due last week", status: .completed, dueInDays: -7, position: "0005")
            ],
            "seeded-long-subtasks": [
                task("long-parent", "Parent with 12 subtasks", position: "0001")
            ] + longSubtasks,
            "seeded-empty": []
        ]
    }

    func listTaskLists() async throws -> [TaskList] {
        lists
    }

    func listTasks(listId: String, showCompleted: Bool, showHidden: Bool) async throws -> [TaskItem] {
        let tasks = tasksByListID[listId] ?? []
        return showCompleted ? tasks : tasks.filter { !$0.isCompleted }
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
            position: String(format: "%04d", (tasksByListID[listId]?.count ?? 0) + 1),
            updated: nil
        )
        tasksByListID[listId, default: []].insert(task, at: 0)
        return task
    }

    func updateTask(listId: String, taskId: String, task: TaskItem) async throws -> TaskItem {
        if let index = tasksByListID[listId]?.firstIndex(where: { $0.id == taskId }) {
            tasksByListID[listId]?[index] = task
        }
        return task
    }

    func deleteTask(listId: String, taskId: String) async throws {
        let tasks = tasksByListID[listId] ?? []
        let childIDs = tasks.filter { $0.parent == taskId }.map(\.id)
        let removedIDs = Set([taskId] + childIDs)
        tasksByListID[listId]?.removeAll { removedIDs.contains($0.id) }
    }

    func moveTask(listId: String, taskId: String, parentId: String?, previousTaskId: String?) async throws -> TaskItem {
        guard let tasks = tasksByListID[listId],
              let reordered = tasksReorderedAfterMove(
                tasks,
                movedTaskID: taskId,
                newParentID: parentId,
                previousTaskID: previousTaskId
              ),
              let movedTask = reordered.first(where: { $0.id == taskId })
        else {
            throw APIError.serverError(400, "Invalid move")
        }
        tasksByListID[listId] = reordered
        return movedTask
    }
}
