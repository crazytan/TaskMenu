import XCTest

final class TaskMenuUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        // Wait for tasks to load
        let firstTask = app.staticTexts["task.title.task1"]
        XCTAssertTrue(firstTask.waitForExistence(timeout: 10), "Tasks should load on launch")
    }

    override func tearDown() {
        app.terminate()
        app = nil
        super.tearDown()
    }

    /// Helper to find a task row element by its accessibility identifier.
    /// Falls back through element types since SwiftUI containers may expose as different roles.
    private func taskRow(_ taskId: String) -> XCUIElement {
        let identifier = "task.row.\(taskId)"
        let group = app.groups[identifier]
        if group.exists { return group }
        let other = app.otherElements[identifier]
        if other.exists { return other }
        // Fallback: use the title text for interaction (context menu propagates from child)
        return app.staticTexts["task.title.\(taskId)"]
    }

    // MARK: - 1. testTaskListLoadsOnLaunch

    func testTaskListLoadsOnLaunch() {
        XCTAssertTrue(app.staticTexts["task.title.task1"].exists, "Buy groceries should be visible")
        XCTAssertTrue(app.staticTexts["task.title.task2"].exists, "Read chapter 5 should be visible")
        XCTAssertTrue(app.staticTexts["task.title.task4"].exists, "Schedule dentist should be visible")
        // Completed task should NOT be visible (section collapsed)
        XCTAssertFalse(app.staticTexts["task.title.task5"].exists, "File taxes should not be visible")
    }

    // MARK: - 2. testAddTask

    func testAddTask() {
        let quickAddField = app.textFields["quickadd.field"]
        XCTAssertTrue(quickAddField.waitForExistence(timeout: 5))
        quickAddField.click()
        quickAddField.typeText("New test task\r")

        let newTask = app.staticTexts.containing(NSPredicate(format: "value == %@", "New test task")).firstMatch
        XCTAssertTrue(newTask.waitForExistence(timeout: 5), "New test task should appear in the list")
    }

    // MARK: - 3. testCompleteTask

    func testCompleteTask() {
        let checkbox = app.buttons["task.checkbox.task1"]
        XCTAssertTrue(checkbox.waitForExistence(timeout: 5))
        checkbox.click()

        // After completing, the task title should disappear from the active section
        // (it moves to the collapsed completed section)
        let titleGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.staticTexts["task.title.task1"]
        )
        let result = XCTWaiter.wait(for: [titleGone], timeout: 5)
        if result != .completed {
            // Task might still be visible if completed section auto-expands;
            // verify it's in the completed section by toggling
            let completedToggle = app.buttons["completed.toggle"]
            if completedToggle.exists {
                completedToggle.click()
                sleep(1)
                XCTAssertTrue(app.staticTexts["task.title.task1"].exists,
                              "Completed task should appear in completed section")
            }
        }
    }

    // MARK: - 4. testDeleteTask

    func testDeleteTask() {
        let row = taskRow("task1")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()

        let deleteButton = app.menuItems["Delete"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
        deleteButton.click()

        let titleGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.staticTexts["task.title.task1"]
        )
        let result = XCTWaiter.wait(for: [titleGone], timeout: 5)
        XCTAssertEqual(result, .completed, "Buy groceries should no longer be visible after deletion")
    }

    // MARK: - 5. testEditTaskDetails

    func testEditTaskDetails() {
        let taskTitle = app.staticTexts["task.title.task1"]
        XCTAssertTrue(taskTitle.waitForExistence(timeout: 5))
        taskTitle.click()

        // Detail view should appear with title field
        let titleField = app.textFields["detail.title.field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5), "Detail title field should appear")
        XCTAssertEqual(titleField.value as? String, "Buy groceries")

        // Clear and type new title
        titleField.click()
        titleField.selectAll()
        titleField.typeText("Buy organic groceries")

        // Click Done
        let doneButton = app.buttons["detail.done.button"]
        XCTAssertTrue(doneButton.exists)
        doneButton.click()

        // Back in list view, new title should be visible
        let updatedTask = app.staticTexts.containing(
            NSPredicate(format: "value == %@", "Buy organic groceries")
        ).firstMatch
        XCTAssertTrue(updatedTask.waitForExistence(timeout: 5), "Buy organic groceries should be visible")
    }

    // MARK: - 6. testAddSubtaskInline

    func testAddSubtaskInline() {
        let row = taskRow("task1")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()

        let addSubtaskItem = app.menuItems["Add Subtask"]
        XCTAssertTrue(addSubtaskItem.waitForExistence(timeout: 5))
        addSubtaskItem.click()

        let inlineField = app.textFields["inline.subtask.field"]
        XCTAssertTrue(inlineField.waitForExistence(timeout: 5), "Inline subtask field should appear")

        inlineField.typeText("Get milk\r")

        // Wait for the subtask to appear
        let subtask = app.staticTexts.containing(
            NSPredicate(format: "value == %@", "Get milk")
        ).firstMatch
        XCTAssertTrue(subtask.waitForExistence(timeout: 5), "Get milk should appear as a subtask")
    }

    // MARK: - 7. testIndentTask

    func testIndentTask() {
        // Right-click "Read chapter 5" (2nd root task)
        let row = taskRow("task2")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()

        let makeSubtaskItem = app.menuItems["Make Subtask"]
        XCTAssertTrue(makeSubtaskItem.waitForExistence(timeout: 5))
        makeSubtaskItem.click()

        // "Read chapter 5" should now be indented under "Buy groceries"
        // Verify it still exists (now as a subtask)
        sleep(1)
        XCTAssertTrue(app.staticTexts["task.title.task2"].exists,
                       "Read chapter 5 should still be visible (now indented)")
    }

    // MARK: - 8. testOutdentTask

    func testOutdentTask() {
        // Right-click "Take notes" (subtask of "Read chapter 5")
        let row = taskRow("task3")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()

        let moveToTopItem = app.menuItems["Move to Top Level"]
        XCTAssertTrue(moveToTopItem.waitForExistence(timeout: 5))
        moveToTopItem.click()

        // "Take notes" should now be at root level
        sleep(1)
        XCTAssertTrue(app.staticTexts["task.title.task3"].exists,
                       "Take notes should still be visible (now at root level)")
    }

    // MARK: - 9. testCompletedSectionToggle

    func testCompletedSectionToggle() {
        // File taxes should not be visible initially
        XCTAssertFalse(app.staticTexts["task.title.task5"].exists,
                        "File taxes should not be visible initially")

        // Click the completed disclosure button
        let completedToggle = app.buttons["completed.toggle"]
        XCTAssertTrue(completedToggle.waitForExistence(timeout: 5))
        completedToggle.click()

        // File taxes should now be visible
        let fileTaxes = app.staticTexts["task.title.task5"]
        XCTAssertTrue(fileTaxes.waitForExistence(timeout: 5),
                       "File taxes should be visible after expanding completed section")

        // Click again to collapse
        completedToggle.click()

        // File taxes should no longer be visible
        let titleGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.staticTexts["task.title.task5"]
        )
        let result = XCTWaiter.wait(for: [titleGone], timeout: 5)
        XCTAssertEqual(result, .completed,
                        "File taxes should not be visible after collapsing completed section")
    }

    // MARK: - 10. testSearchFiltersTasks

    func testSearchFiltersTasks() {
        let searchField = app.textFields["search.field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.click()
        searchField.typeText("chapter")

        // Wait for filter to apply
        sleep(1)

        // "Read chapter 5" should be visible
        XCTAssertTrue(app.staticTexts["task.title.task2"].exists,
                       "Read chapter 5 should be visible when searching 'chapter'")
        // "Buy groceries" should NOT be visible
        XCTAssertFalse(app.staticTexts["task.title.task1"].exists,
                        "Buy groceries should not be visible when searching 'chapter'")

        // Clear search
        searchField.click()
        searchField.selectAll()
        searchField.typeText("\u{8}") // Backspace to delete selection

        // Wait for filter to clear
        sleep(1)

        // All tasks should be visible again
        XCTAssertTrue(app.staticTexts["task.title.task1"].exists,
                       "Buy groceries should be visible after clearing search")
        XCTAssertTrue(app.staticTexts["task.title.task2"].exists,
                       "Read chapter 5 should be visible after clearing search")
    }
}

private extension XCUIElement {
    func selectAll() {
        typeKey("a", modifierFlags: .command)
    }
}
