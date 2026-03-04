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

    var selectedList: TaskList? {
        taskLists.first { $0.id == selectedListId }
    }

    private let authService: GoogleAuthService
    private let api: GoogleTasksAPI

    init(authService: GoogleAuthService = GoogleAuthService(), api: GoogleTasksAPI? = nil) {
        self.authService = authService
        self.api = api ?? GoogleTasksAPI(authService: authService)
        self.isSignedIn = authService.isSignedIn
    }

    func signIn() async {
        do {
            try await authService.signIn()
            isSignedIn = true
            await loadTaskLists()
        } catch {
            errorMessage = "Sign in failed: \(error.localizedDescription)"
        }
    }

    func signOut() {
        authService.signOut()
        isSignedIn = false
        taskLists = []
        tasks = []
        selectedListId = nil
    }

    func loadTaskLists() async {
        isLoading = true
        defer { isLoading = false }
        do {
            taskLists = try await api.listTaskLists()
            if selectedListId == nil, let first = taskLists.first {
                selectedListId = first.id
            }
            await loadTasks()
        } catch {
            handleError(error)
        }
    }

    func loadTasks() async {
        guard let listId = selectedListId else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            tasks = try await api.listTasks(listId: listId)
        } catch {
            handleError(error)
        }
    }

    func addTask(title: String) async {
        guard let listId = selectedListId else { return }
        do {
            let task = try await api.createTask(listId: listId, title: title)
            tasks.insert(task, at: 0)
        } catch {
            handleError(error)
        }
    }

    func toggleTask(_ task: TaskItem) async {
        guard let listId = selectedListId else { return }
        var updated = task
        updated.isCompleted.toggle()
        do {
            let result = try await api.updateTask(listId: listId, taskId: task.id, task: updated)
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index] = result
            }
        } catch {
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
        } catch {
            handleError(error)
        }
    }

    func deleteTask(_ task: TaskItem) async {
        guard let listId = selectedListId else { return }
        do {
            try await api.deleteTask(listId: listId, taskId: task.id)
            tasks.removeAll { $0.id == task.id }
        } catch {
            handleError(error)
        }
    }

    func selectList(_ listId: String) async {
        selectedListId = listId
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
}
