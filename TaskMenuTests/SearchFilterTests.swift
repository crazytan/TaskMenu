import XCTest
@testable import TaskMenu

@MainActor
final class SearchFilterTests: XCTestCase {

    // MARK: - Helpers

    private func makeTask(
        id: String,
        title: String,
        notes: String? = nil,
        parent: String? = nil,
        status: TaskItem.TaskStatus = .needsAction,
        position: String? = nil,
        dueInDays: Int? = nil
    ) -> TaskItem {
        TaskItem(
            id: id,
            title: title,
            notes: notes,
            status: status,
            due: dueInDays.map { days in
                let date = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
                return DateFormatting.formatGoogleTaskDueDate(date)
            },
            selfLink: nil,
            parent: parent,
            position: position,
            updated: nil
        )
    }

    /// Isolated defaults so preference writes never touch the test host's
    /// real domain.
    private func makeAppState(tasks: [TaskItem]) -> AppState {
        let suiteName = "dev.crazytan.TaskMenu.tests.search.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName) ?? .standard
        userDefaults.removePersistentDomain(forName: suiteName)
        let state = AppState(userDefaults: userDefaults)
        state.tasks = tasks
        return state
    }

    // MARK: - Empty Search Returns All Tasks

    func testEmptySearchReturnsAllTasks() {
        let tasks = [
            makeTask(id: "1", title: "Buy groceries"),
            makeTask(id: "2", title: "Walk the dog"),
        ]
        let state = makeAppState(tasks: tasks)
        state.searchText = ""

        XCTAssertEqual(state.searchFilteredTasks.count, 2)
        XCTAssertFalse(state.isSearching)
    }

    func testWhitespaceOnlySearchReturnsAllTasks() {
        let tasks = [
            makeTask(id: "1", title: "Buy groceries"),
        ]
        let state = makeAppState(tasks: tasks)
        state.searchText = "   "

        XCTAssertEqual(state.searchFilteredTasks.count, 1)
        XCTAssertFalse(state.isSearching)
    }

    // MARK: - Title Matching

    func testSearchMatchesTitleCaseInsensitive() {
        let tasks = [
            makeTask(id: "1", title: "Buy Groceries"),
            makeTask(id: "2", title: "Walk the dog"),
        ]
        let state = makeAppState(tasks: tasks)
        state.searchText = "buy"

        XCTAssertTrue(state.isSearching)
        XCTAssertEqual(state.searchFilteredTasks.count, 1)
        XCTAssertEqual(state.searchFilteredTasks.first?.id, "1")
    }

    func testSearchMatchesPartialTitle() {
        let tasks = [
            makeTask(id: "1", title: "Buy groceries"),
            makeTask(id: "2", title: "Walk the dog"),
        ]
        let state = makeAppState(tasks: tasks)
        state.searchText = "groc"

        XCTAssertEqual(state.searchFilteredTasks.count, 1)
        XCTAssertEqual(state.searchFilteredTasks.first?.id, "1")
    }

    // MARK: - Notes Matching

    func testSearchMatchesNotes() {
        let tasks = [
            makeTask(id: "1", title: "Shopping", notes: "Milk, eggs, bread"),
            makeTask(id: "2", title: "Exercise"),
        ]
        let state = makeAppState(tasks: tasks)
        state.searchText = "milk"

        XCTAssertEqual(state.searchFilteredTasks.count, 1)
        XCTAssertEqual(state.searchFilteredTasks.first?.id, "1")
    }

    func testSearchMatchesNotesCaseInsensitive() {
        let tasks = [
            makeTask(id: "1", title: "Shopping", notes: "Buy ORGANIC milk"),
        ]
        let state = makeAppState(tasks: tasks)
        state.searchText = "organic"

        XCTAssertEqual(state.searchFilteredTasks.count, 1)
    }

    // MARK: - No Results

    func testSearchWithNoMatchReturnsEmpty() {
        let tasks = [
            makeTask(id: "1", title: "Buy groceries"),
            makeTask(id: "2", title: "Walk the dog"),
        ]
        let state = makeAppState(tasks: tasks)
        state.searchText = "xyz"

        XCTAssertTrue(state.isSearching)
        XCTAssertTrue(state.searchFilteredTasks.isEmpty)
    }

    // MARK: - Subtask Visibility

    func testMatchingSubtaskShowsParent() {
        let tasks = [
            makeTask(id: "parent1", title: "Shopping"),
            makeTask(id: "child1", title: "Buy milk", parent: "parent1"),
            makeTask(id: "parent2", title: "Work"),
        ]
        let state = makeAppState(tasks: tasks)
        state.searchText = "milk"

        let filtered = state.searchFilteredTasks
        let filteredIDs = Set(filtered.map(\.id))
        // Both the matching subtask and its parent should be visible
        XCTAssertTrue(filteredIDs.contains("child1"))
        XCTAssertTrue(filteredIDs.contains("parent1"))
        // Unrelated parent should not be visible
        XCTAssertFalse(filteredIDs.contains("parent2"))
    }

    func testMatchingSubtaskWithNonMatchingParent() {
        let tasks = [
            makeTask(id: "parent1", title: "Errands"),
            makeTask(id: "child1", title: "Pick up prescription", parent: "parent1"),
        ]
        let state = makeAppState(tasks: tasks)
        state.searchText = "prescription"

        let filteredIDs = Set(state.searchFilteredTasks.map(\.id))
        XCTAssertTrue(filteredIDs.contains("child1"))
        XCTAssertTrue(filteredIDs.contains("parent1"))
    }

    func testMatchingParentWithNonMatchingSubtask() {
        let tasks = [
            makeTask(id: "parent1", title: "Shopping list"),
            makeTask(id: "child1", title: "Eggs", parent: "parent1"),
            makeTask(id: "child2", title: "Bread", parent: "parent1"),
        ]
        let state = makeAppState(tasks: tasks)
        state.searchText = "shopping"

        let filteredIDs = Set(state.searchFilteredTasks.map(\.id))
        // Parent matches directly
        XCTAssertTrue(filteredIDs.contains("parent1"))
        // Non-matching subtasks should not appear
        XCTAssertFalse(filteredIDs.contains("child1"))
        XCTAssertFalse(filteredIDs.contains("child2"))
    }

    // MARK: - Completed Tasks in Search

    func testSearchIncludesCompletedTasks() {
        let tasks = [
            makeTask(id: "1", title: "Buy groceries", status: .completed),
            makeTask(id: "2", title: "Buy shoes", status: .needsAction),
            makeTask(id: "3", title: "Walk the dog"),
        ]
        let state = makeAppState(tasks: tasks)
        state.searchText = "buy"

        let filtered = state.searchFilteredTasks
        XCTAssertEqual(filtered.count, 2)
        let filteredIDs = Set(filtered.map(\.id))
        XCTAssertTrue(filteredIDs.contains("1"))
        XCTAssertTrue(filteredIDs.contains("2"))
    }

    func testSearchIncludesMatchingCompletedSubtaskAndParent() {
        let tasks = [
            makeTask(id: "parent1", title: "Errands"),
            makeTask(id: "child1", title: "Renew passport", parent: "parent1", status: .completed),
            makeTask(id: "child2", title: "Buy stamps", parent: "parent1"),
        ]
        let state = makeAppState(tasks: tasks)
        state.searchText = "passport"

        let filteredIDs = Set(state.searchFilteredTasks.map(\.id))
        XCTAssertTrue(filteredIDs.contains("parent1"))
        XCTAssertTrue(filteredIDs.contains("child1"))
        XCTAssertFalse(filteredIDs.contains("child2"))

        XCTAssertEqual(state.searchFilteredSubtasks(of: "parent1").map(\.id), ["child1"])
    }

    // MARK: - Search Filtered Root Tasks

    func testSearchFilteredRootTasksExcludesSubtasks() {
        let tasks = [
            makeTask(id: "parent1", title: "Shopping"),
            makeTask(id: "child1", title: "Buy shopping bags", parent: "parent1"),
        ]
        let state = makeAppState(tasks: tasks)
        state.searchText = "shopping"

        // Only root tasks in the filtered root set
        XCTAssertEqual(state.searchFilteredRootTasks.count, 1)
        XCTAssertEqual(state.searchFilteredRootTasks.first?.id, "parent1")
    }

    // MARK: - Search Match Count

    func testSearchMatchCountExcludesContextParents() {
        let tasks = [
            makeTask(id: "parent1", title: "Errands"),
            makeTask(id: "child1", title: "Overdue bill", parent: "parent1"),
            makeTask(id: "task2", title: "Overdue library book"),
        ]
        let state = makeAppState(tasks: tasks)
        state.searchText = "overdue"

        // The non-matching parent is visible for context but is not a result.
        XCTAssertEqual(state.searchFilteredTasks.count, 3)
        XCTAssertEqual(state.searchMatchCount, 2)
    }

    func testSearchMatchCountEqualsDirectMatchesForRootMatches() {
        let tasks = [
            makeTask(id: "1", title: "Buy groceries"),
            makeTask(id: "2", title: "Buy shoes"),
            makeTask(id: "3", title: "Walk the dog"),
        ]
        let state = makeAppState(tasks: tasks)
        state.searchText = "buy"

        XCTAssertEqual(state.searchMatchCount, 2)
    }

    func testSearchMatchCountIsZeroWhenNotSearching() {
        let state = makeAppState(tasks: [makeTask(id: "1", title: "Buy groceries")])
        state.searchText = ""

        XCTAssertEqual(state.searchMatchCount, 0)
    }

    // MARK: - Search Filtered Subtasks

    func testSearchFilteredSubtasks() {
        let tasks = [
            makeTask(id: "parent1", title: "Errands"),
            makeTask(id: "child1", title: "Buy milk", parent: "parent1"),
            makeTask(id: "child2", title: "Buy eggs", parent: "parent1"),
            makeTask(id: "child3", title: "Walk dog", parent: "parent1"),
        ]
        let state = makeAppState(tasks: tasks)
        state.searchText = "buy"

        let subtasks = state.searchFilteredSubtasks(of: "parent1")
        XCTAssertEqual(subtasks.count, 2)
        let subtaskIDs = Set(subtasks.map(\.id))
        XCTAssertTrue(subtaskIDs.contains("child1"))
        XCTAssertTrue(subtaskIDs.contains("child2"))
    }

    // MARK: - Sort Order

    func testSearchFilteredRootTasksFollowDueDateSort() {
        let state = makeAppState(tasks: [
            makeTask(id: "alpha", title: "Alpha later", position: "00000000", dueInDays: 3),
            makeTask(id: "alpha-2", title: "Alpha overdue", position: "00000001", dueInDays: -1),
            makeTask(id: "beta", title: "Beta today", position: "00000002", dueInDays: 0),
        ])
        state.searchText = "alpha"

        state.taskSortOrder = .dueDate
        XCTAssertEqual(state.searchFilteredRootTasks.map(\.id), ["alpha-2", "alpha"])

        state.taskSortOrder = .myOrder
        XCTAssertEqual(state.searchFilteredRootTasks.map(\.id), ["alpha", "alpha-2"])
    }
}
