import AppKit
import XCTest
@testable import TaskMenu

final class TaskListViewTests: XCTestCase {
    private func makeTask(
        id: String,
        title: String = "Task",
        parent: String? = nil,
        status: TaskItem.TaskStatus = .needsAction,
        position: String? = nil
    ) -> TaskItem {
        TaskItem(
            id: id,
            title: title,
            notes: nil,
            status: status,
            due: nil,
            selfLink: nil,
            parent: parent,
            position: position,
            updated: nil
        )
    }

    @MainActor
    func testTaskListScrollIndicatorsUseTransientOverlayStyle() {
        let scrollView = NSScrollView()
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy

        TaskMenuAppKit.configureTaskListScrollIndicators(scrollView)

        XCTAssertTrue(scrollView.hasVerticalScroller)
        XCTAssertFalse(scrollView.hasHorizontalScroller)
        XCTAssertTrue(scrollView.autohidesScrollers)
        XCTAssertEqual(scrollView.scrollerStyle, .overlay)
    }

    @MainActor
    func testTextFieldEscapeInvokesOnEscapeAndClaimsEvent() {
        let field = TaskMenuTextField(placeholder: "Add task")
        var escaped = false
        field.onEscape = { escaped = true }

        let handled = field.control(
            field,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        )

        XCTAssertTrue(handled)
        XCTAssertTrue(escaped)
    }

    @MainActor
    func testTextFieldEscapeWithoutHandlerPassesThrough() {
        let field = TaskMenuTextField(placeholder: "Add task")

        let handled = field.control(
            field,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        )

        XCTAssertFalse(handled)
    }

    func testTaskNotesPreviewTrimsWhitespace() {
        let task = TaskItem(
            id: "with-notes",
            title: "Subtask",
            notes: "  Pack the charger\n",
            status: .needsAction,
            due: nil,
            selfLink: nil,
            parent: "parent",
            position: nil,
            updated: nil
        )

        XCTAssertEqual(taskNotesPreview(for: task), "Pack the charger")
    }

    func testTaskNotesPreviewHidesEmptyNotes() {
        let task = TaskItem(
            id: "empty-notes",
            title: "Subtask",
            notes: "  \n",
            status: .needsAction,
            due: nil,
            selfLink: nil,
            parent: "parent",
            position: nil,
            updated: nil
        )

        XCTAssertNil(taskNotesPreview(for: task))
    }

    func testSubtasksWithCompletedLastPreservesRelativeOrderWithinGroups() {
        let firstDone = makeTask(id: "done-1", parent: "parent", status: .completed)
        let firstActive = makeTask(id: "active-1", parent: "parent")
        let secondDone = makeTask(id: "done-2", parent: "parent", status: .completed)
        let secondActive = makeTask(id: "active-2", parent: "parent")

        let ordered = subtasksWithCompletedLast([firstDone, firstActive, secondDone, secondActive])

        XCTAssertEqual(ordered.map(\.id), ["active-1", "active-2", "done-1", "done-2"])
    }

    func testFinalCompletedSectionExcludesCompletedSubtasksOfOpenParents() {
        let openParent = makeTask(id: "open-parent", position: "0001")
        let completedChildOfOpenParent = makeTask(
            id: "open-child-done",
            parent: "open-parent",
            status: .completed,
            position: "0001"
        )
        let completedRoot = makeTask(id: "done-root", status: .completed, position: "0002")
        let completedParent = makeTask(id: "done-parent", status: .completed, position: "0003")
        let completedChildOfCompletedParent = makeTask(
            id: "done-child",
            parent: "done-parent",
            status: .completed,
            position: "0001"
        )

        let completedTasks = completedTasksForFinalSection([
            openParent,
            completedChildOfOpenParent,
            completedRoot,
            completedParent,
            completedChildOfCompletedParent
        ])

        XCTAssertEqual(completedTasks.map(\.id), ["done-root", "done-parent", "done-child"])
    }

    func testFinalCompletedSectionIncludesIncompleteChildOfCompletedParent() {
        let completedParent = makeTask(id: "done-parent", status: .completed, position: "0001")
        let incompleteChild = makeTask(id: "open-child", parent: "done-parent", position: "0001")
        let completedChild = makeTask(
            id: "done-child",
            parent: "done-parent",
            status: .completed,
            position: "0002"
        )

        let completedTasks = completedTasksForFinalSection([
            completedParent,
            incompleteChild,
            completedChild
        ])

        XCTAssertEqual(completedTasks.map(\.id), ["done-parent", "open-child", "done-child"])
    }

    func testTaskListActivationKeyCodesAreReturnAndKeypadEnter() {
        XCTAssertTrue(TaskListKeyboardCommands.isActivationKeyCode(36)) // Return
        XCTAssertTrue(TaskListKeyboardCommands.isActivationKeyCode(76)) // keypad Enter
        XCTAssertFalse(TaskListKeyboardCommands.isActivationKeyCode(125)) // down arrow
        XCTAssertFalse(TaskListKeyboardCommands.isActivationKeyCode(126)) // up arrow
        XCTAssertFalse(TaskListKeyboardCommands.isActivationKeyCode(49)) // space
    }

    @MainActor
    func testKeyboardSelectionBrowsesWithoutOpeningAndReturnOpensSelectedTask() throws {
        let state = AppState()
        state.tasks = [
            makeTask(id: "1", title: "First"),
            makeTask(id: "2", title: "Second")
        ]
        let content = TaskListContentView()
        var openedTaskIDs: [String] = []
        content.onOpenTask = { openedTaskIDs.append($0.id) }
        content.render(appState: state, showCompleted: false, expandedCompletedSubtaskParentIDs: [])

        let outline = try XCTUnwrap(findOutlineView(in: content))

        // Moving the selection (what arrow keys do) must not navigate.
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertTrue(openedTaskIDs.isEmpty)
        XCTAssertEqual(outline.selectedRow, 1)

        // Return opens the selected row and clears the selection highlight.
        let returnKey = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))
        outline.keyDown(with: returnKey)
        XCTAssertEqual(openedTaskIDs, ["2"])
        XCTAssertEqual(outline.selectedRow, -1)
    }

    @MainActor
    private func findOutlineView(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView {
            return outline
        }
        for subview in view.subviews {
            if let found = findOutlineView(in: subview) {
                return found
            }
        }
        return nil
    }

    func testSearchResultCountTextUsesSingularAndPlural() {
        XCTAssertEqual(searchResultCountText(0), "0 results")
        XCTAssertEqual(searchResultCountText(1), "1 result")
        XCTAssertEqual(searchResultCountText(5), "5 results")
    }

    @MainActor
    func testCompletedSectionSourceTasksUsesFilteredSetWhileSearching() {
        let state = AppState()
        state.tasks = [
            makeTask(id: "done-match", title: "Buy milk", status: .completed),
            makeTask(id: "done-other", title: "Walk dog", status: .completed),
            makeTask(id: "open-match", title: "Buy eggs")
        ]

        state.searchText = ""
        XCTAssertEqual(
            TaskListPresentation.completedSectionSourceTasks(from: state).map(\.id),
            ["done-match", "done-other", "open-match"]
        )

        state.searchText = "buy"
        XCTAssertEqual(
            TaskListPresentation.completedSectionSourceTasks(from: state).map(\.id),
            ["done-match", "open-match"]
        )
    }

    @MainActor
    func testDisplaySubtasksShowsOnlyMatchingChildrenWhileSearching() {
        let state = AppState()
        state.tasks = [
            makeTask(id: "parent", title: "Errands"),
            makeTask(id: "done-child", title: "Renew passport", parent: "parent", status: .completed),
            makeTask(id: "open-child", title: "Buy stamps", parent: "parent")
        ]

        state.searchText = "passport"
        XCTAssertEqual(
            TaskListPresentation.displaySubtasks(of: "parent", from: state).map(\.id),
            ["done-child"]
        )

        state.searchText = ""
        XCTAssertEqual(
            TaskListPresentation.displaySubtasks(of: "parent", from: state).map(\.id),
            ["done-child", "open-child"]
        )
    }

    func testCompletedSubtasksForOpenParentReturnsOnlyThatParentsCompletedChildren() {
        let firstDone = makeTask(id: "done-1", parent: "parent", status: .completed, position: "0002")
        let activeChild = makeTask(id: "active-1", parent: "parent", position: "0001")
        let otherDone = makeTask(id: "other-done", parent: "other", status: .completed, position: "0001")
        let secondDone = makeTask(id: "done-2", parent: "parent", status: .completed, position: "0003")

        let completedSubtasks = completedSubtasksForOpenParent(
            "parent",
            tasks: [firstDone, activeChild, otherDone, secondDone]
        )

        XCTAssertEqual(completedSubtasks.map(\.id), ["done-1", "done-2"])
    }

    /// The row chevron is the only way to fold subtasks away, so it has to move
    /// rows in and out of the outline, not just flip `collapsedTaskIDs`.
    @MainActor
    func testSubtaskChevronHidesAndShowsSubtaskRows() throws {
        let state = AppState()
        state.tasks = [
            makeTask(id: "parent", title: "Parent", position: "0001"),
            makeTask(id: "child-1", title: "Child 1", parent: "parent", position: "0001"),
            makeTask(id: "child-2", title: "Child 2", parent: "parent", position: "0002")
        ]

        let content = TaskListContentView()
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        host.contentView?.addSubview(content)
        content.frame = NSRect(x: 0, y: 0, width: 360, height: 400)

        let render = {
            content.render(appState: state, showCompleted: false, expandedCompletedSubtaskParentIDs: [])
        }
        content.onToggleCollapsed = { taskID in
            state.toggleCollapsed(taskID)
            render()
        }

        render()
        let outline = try XCTUnwrap(findOutlineView(in: content))
        XCTAssertEqual(outline.numberOfRows, 3, "parent plus both subtasks")

        // A second render puts the view on the animated diff path, which is what
        // a chevron tap goes through in the running app.
        render()

        try clickSubtaskChevron(inRowZeroOf: outline)
        XCTAssertEqual(state.collapsedTaskIDs, ["parent"])
        XCTAssertEqual(outline.numberOfRows, 1, "subtask rows are hidden while collapsed")

        try clickSubtaskChevron(inRowZeroOf: outline)
        XCTAssertTrue(state.collapsedTaskIDs.isEmpty)
        XCTAssertEqual(outline.numberOfRows, 3, "subtask rows come back when expanded")
    }

    /// A full reload (list switch, search change) rebuilds every row, so the
    /// collapsed parents have to come back collapsed.
    @MainActor
    func testFullReloadKeepsCollapsedSubtasksHidden() throws {
        let state = AppState()
        state.tasks = [
            makeTask(id: "parent", title: "Parent", position: "0001"),
            makeTask(id: "child", title: "Child", parent: "parent", position: "0001")
        ]
        state.collapsedTaskIDs = ["parent"]

        let content = TaskListContentView()
        content.render(appState: state, showCompleted: false, expandedCompletedSubtaskParentIDs: [])

        let outline = try XCTUnwrap(findOutlineView(in: content))
        XCTAssertEqual(outline.numberOfRows, 1, "collapsed parent renders without its subtask")

        state.collapsedTaskIDs = []
        content.render(appState: state, showCompleted: false, expandedCompletedSubtaskParentIDs: [])
        XCTAssertEqual(outline.numberOfRows, 2)
    }

    @MainActor
    private func clickSubtaskChevron(inRowZeroOf outline: NSOutlineView) throws {
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let chevron = try XCTUnwrap(
            buttons(in: cell).first { ($0.toolTip ?? "").localizedCaseInsensitiveContains("subtasks of") },
            "row 0 should offer a subtask disclosure chevron"
        )
        chevron.performClick(nil)
    }

    @MainActor
    private func buttons(in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        if let button = view as? NSButton {
            found.append(button)
        }
        for subview in view.subviews {
            found.append(contentsOf: buttons(in: subview))
        }
        return found
    }
}
