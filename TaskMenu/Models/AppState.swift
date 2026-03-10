import AppKit
import SwiftUI

@MainActor
@Observable
final class AppState {
    var isSignedIn = false
    var isLoading = false
    var errorMessage: String?

    var taskLists: [TaskList] = []
    var selectedListId: String?
    var tasks: [TaskItem] = []
    var globalShortcutEnabled: Bool {
        didSet {
            userDefaults.set(
                globalShortcutEnabled,
                forKey: Constants.UserDefaults.globalShortcutEnabledKey
            )
            shortcutMonitor.setEnabled(globalShortcutEnabled)
        }
    }
    var dueDateNotificationsEnabled: Bool {
        didSet {
            userDefaults.set(
                dueDateNotificationsEnabled,
                forKey: Constants.UserDefaults.dueDateNotificationsEnabledKey
            )
            let enabled = dueDateNotificationsEnabled
            Task { [weak self] in
                guard let self else { return }
                await self.applyDueDateNotificationsPreferenceChange(enabled: enabled)
            }
        }
    }

    var selectedList: TaskList? {
        taskLists.first { $0.id == selectedListId }
    }

    private let authService: GoogleAuthService
    private let api: GoogleTasksAPI
    private let userDefaults: UserDefaults
    private let shortcutMonitor: GlobalShortcutMonitoring
    private let dueDateNotificationService: any DueDateNotificationServicing

    /// Whether completed tasks have been fetched for the current list
    private var completedTasksFetched = false
    /// In-memory cache of completed tasks for the current list
    private var completedTasksCache: [TaskItem] = []

    init(
        authService: GoogleAuthService = GoogleAuthService(),
        api: GoogleTasksAPI? = nil,
        userDefaults: UserDefaults = .standard,
        shortcutMonitor: GlobalShortcutMonitoring? = nil,
        dueDateNotificationService: any DueDateNotificationServicing = DueDateNotificationService()
    ) {
        self.authService = authService
        self.api = api ?? GoogleTasksAPI(authService: authService)
        self.userDefaults = userDefaults
        self.shortcutMonitor = shortcutMonitor ?? GlobalShortcutMonitor()
        self.dueDateNotificationService = dueDateNotificationService
        self.globalShortcutEnabled = userDefaults.object(
            forKey: Constants.UserDefaults.globalShortcutEnabledKey
        ) as? Bool ?? true
        self.dueDateNotificationsEnabled = userDefaults.object(
            forKey: Constants.UserDefaults.dueDateNotificationsEnabledKey
        ) as? Bool ?? true
        self.isSignedIn = authService.isSignedIn

        self.shortcutMonitor.setHandler { [weak self] in
            self?.toggleMenuBarPopover()
        }
        self.shortcutMonitor.setEnabled(globalShortcutEnabled)
    }

    private var signInTask: Task<Void, Never>?

    deinit {
        MainActor.assumeIsolated {
            signInTask?.cancel()
            shortcutMonitor.invalidate()
        }
    }

    func signIn() {
        signInTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await authService.signIn()
                self.isSignedIn = true
                await self.loadTaskLists()
            } catch {
                self.errorMessage = "Sign in failed: \(error.localizedDescription)"
            }
        }
    }

    func signOut() {
        authService.signOut()
        isSignedIn = false
        taskLists = []
        tasks = []
        selectedListId = nil
        completedTasksFetched = false
        completedTasksCache = []
        let dueDateNotificationService = dueDateNotificationService
        Task {
            await dueDateNotificationService.removeAllNotifications()
        }
    }

    func loadTaskLists() async {
        isLoading = true
        defer { isLoading = false }
        do {
            taskLists = try await api.listTaskLists()
            if selectedListId == nil, let first = taskLists.first {
                selectedListId = first.id
            }
            await refreshTasks()
        } catch {
            handleError(error)
        }
    }

    /// Loads active tasks (always fresh) and completed tasks (from cache if available).
    func loadTasks() async {
        guard let listId = selectedListId else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let activeTasks = try await api.listTasks(listId: listId, showCompleted: false, showHidden: false)
            if completedTasksFetched {
                tasks = activeTasks + completedTasksCache
            } else {
                let completed = try await api.listTasks(listId: listId, showCompleted: true, showHidden: true)
                    .filter { $0.isCompleted }
                completedTasksCache = completed
                completedTasksFetched = true
                tasks = activeTasks + completed
            }
            await syncDueDateNotificationsIfNeeded()
        } catch {
            handleError(error)
        }
    }

    /// Explicit refresh: fetches both active and completed tasks fresh from server.
    func refreshTasks() async {
        guard let listId = selectedListId else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let allTasks = try await api.listTasks(listId: listId)
            completedTasksCache = allTasks.filter { $0.isCompleted }
            completedTasksFetched = true
            tasks = allTasks
            await syncDueDateNotificationsIfNeeded()
        } catch {
            handleError(error)
        }
    }

    func addTask(title: String) async {
        guard let listId = selectedListId else { return }
        do {
            let task = try await api.createTask(listId: listId, title: title)
            tasks.insert(task, at: 0)
            await syncDueDateNotificationsIfNeeded()
        } catch {
            handleError(error)
        }
    }

    func toggleTask(_ task: TaskItem) async {
        guard let listId = selectedListId else { return }
        var updated = task
        updated.isCompleted.toggle()
        
        // Optimistic update: immediately reflect in UI
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = updated
        }
        
        do {
            let result = try await api.updateTask(listId: listId, taskId: task.id, task: updated)
            // Update with server response
            if let index = tasks.firstIndex(where: { $0.id == result.id }) {
                tasks[index] = result
            }
            // Update completed tasks cache
            if result.isCompleted {
                if !completedTasksCache.contains(where: { $0.id == result.id }) {
                    completedTasksCache.append(result)
                }
            } else {
                completedTasksCache.removeAll { $0.id == result.id }
            }
            await syncDueDateNotificationsIfNeeded()
        } catch {
            // Revert optimistic update on failure
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index] = task
            }
            handleError(error)
        }
    }

    func updateTask(_ task: TaskItem) async {
        guard let listId = selectedListId else { return }
        do {
            let result = try await api.updateTask(listId: listId, taskId: task.id, task: task)
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index] = result
            }
            // Keep cache in sync
            if result.isCompleted {
                if let idx = completedTasksCache.firstIndex(where: { $0.id == result.id }) {
                    completedTasksCache[idx] = result
                }
            }
            await syncDueDateNotificationsIfNeeded()
        } catch {
            handleError(error)
        }
    }

    func deleteTask(_ task: TaskItem) async {
        guard let listId = selectedListId else { return }
        do {
            try await api.deleteTask(listId: listId, taskId: task.id)
            tasks.removeAll { $0.id == task.id }
            completedTasksCache.removeAll { $0.id == task.id }
            await dueDateNotificationService.removeNotifications(
                forTaskIDs: [task.id],
                inListID: listId
            )
        } catch {
            handleError(error)
        }
    }

    func moveTask(_ task: TaskItem, toActiveIndex destinationIndex: Int) async {
        guard let listId = selectedListId else { return }
        guard let moveContext = makeMoveContext(for: task.id, destinationIndex: destinationIndex) else {
            return
        }

        let originalTasks = tasks
        tasks = moveContext.reorderedTasks

        do {
            let movedTask = try await api.moveTask(
                listId: listId,
                taskId: task.id,
                previousId: moveContext.previousTaskID,
                parentId: task.parent
            )
            if let index = tasks.firstIndex(where: { $0.id == movedTask.id }) {
                tasks[index] = movedTask
            }
        } catch {
            tasks = originalTasks
            handleError(error)
        }
    }

    func selectList(_ listId: String) async {
        selectedListId = listId
        completedTasksFetched = false
        completedTasksCache = []
        await loadTasks()
    }

    private func handleError(_ error: Error) {
        if let apiError = error as? APIError {
            switch apiError {
            case .unauthorized:
                errorMessage = "Session expired. Please sign in again."
                signOut()
            case .networkError(let underlying):
                errorMessage = "Network error: \(underlying.localizedDescription)"
            case .serverError(let code, let message):
                errorMessage = "Server error \(code): \(message ?? "Unknown")"
            case .decodingError:
                errorMessage = "Failed to parse server response."
            }
        } else {
            errorMessage = error.localizedDescription
        }
    }

    private func applyDueDateNotificationsPreferenceChange(enabled: Bool) async {
        if enabled {
            await syncDueDateNotificationsIfNeeded()
        } else {
            await dueDateNotificationService.removeAllNotifications()
        }
    }

    private func syncDueDateNotificationsIfNeeded() async {
        guard dueDateNotificationsEnabled, let selectedList else { return }
        await dueDateNotificationService.syncNotifications(for: tasks, in: selectedList)
    }

    private func makeMoveContext(for taskID: String, destinationIndex: Int) -> TaskMoveContext? {
        let activeTasks = tasks.filter { !$0.isCompleted }
        guard let sourceIndex = activeTasks.firstIndex(where: { $0.id == taskID }) else { return nil }

        let clampedDestinationIndex = min(max(destinationIndex, 0), activeTasks.count)
        var reorderedActiveTasks = activeTasks
        reorderedActiveTasks.move(
            fromOffsets: IndexSet(integer: sourceIndex),
            toOffset: clampedDestinationIndex
        )

        guard reorderedActiveTasks.map(\.id) != activeTasks.map(\.id) else {
            return nil
        }

        guard let movedTaskIndex = reorderedActiveTasks.firstIndex(where: { $0.id == taskID }) else {
            return nil
        }

        let previousTaskID = movedTaskIndex > 0 ? reorderedActiveTasks[movedTaskIndex - 1].id : nil
        let completedTasks = tasks.filter { $0.isCompleted }

        return TaskMoveContext(
            reorderedTasks: reorderedActiveTasks + completedTasks,
            previousTaskID: previousTaskID
        )
    }

    private func toggleMenuBarPopover() {
        let wasVisible = isMenuBarPopoverVisible

        if !wasVisible {
            NSApp.activate()
        }

        findMenuBarButton()?.performClick(nil)

        if !wasVisible {
            Task { @MainActor in
                self.findVisibleMenuBarPopoverWindow()?.makeKeyAndOrderFront(nil)
            }
        }
    }

    private var isMenuBarPopoverVisible: Bool {
        findVisibleMenuBarPopoverWindow() != nil
    }

    private func findVisibleMenuBarPopoverWindow() -> NSWindow? {
        NSApp.windows.first(where: { Self.isMenuBarPopoverWindow($0) && $0.isVisible })
    }

    private func findMenuBarButton() -> NSStatusBarButton? {
        for window in NSApp.windows where Self.isStatusBarWindow(window) {
            if let button = findMenuBarButton(in: window.contentView) {
                return button
            }
        }
        return nil
    }

    private func findMenuBarButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton {
            return button
        }

        for subview in view.subviews {
            if let button = findMenuBarButton(in: subview) {
                return button
            }
        }

        return nil
    }

    nonisolated private static func isMenuBarPopoverWindow(_ window: NSWindow) -> Bool {
        String(describing: type(of: window)).hasPrefix("MenuBarExtraWindow")
    }

    nonisolated private static func isStatusBarWindow(_ window: NSWindow) -> Bool {
        String(describing: type(of: window)) == "NSStatusBarWindow"
    }
}

private struct TaskMoveContext {
    let reorderedTasks: [TaskItem]
    let previousTaskID: String?
}
