import AppIntents
import Foundation
import WidgetKit

/// Interactive widget button intent: completes one task (cascading to its
/// open direct children when it is a parent) without launching TaskMenu.
/// `listID`/`taskID`/`taskTitle` are stable, persisted system state —
/// treated as untrusted input, never as file paths/URLs, and never used
/// without first checking `taskID` belongs to the cached `listID`. All of
/// that verification/cascade/refetch logic lives in
/// `TaskWidgetCompletionCoordinator` (`TaskMenu/WidgetSupport/`,
/// Foundation-only) so it stays unit-testable from the app target (see
/// `TaskMenuTests/CompleteTaskIntentTests.swift`); this type only wires that
/// coordinator to `AppIntent`/`WidgetCenter`.
struct CompleteTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Complete Task"
    /// Completion must never launch TaskMenu.
    static let openAppWhenRun: Bool = false

    @Parameter(title: "List ID")
    var listID: String
    @Parameter(title: "Task ID")
    var taskID: String
    /// Display-only, for system presentation (e.g. confirmation UI); never
    /// read back to decide what to mutate.
    @Parameter(title: "Task Title")
    var taskTitle: String

    init() {
        listID = ""
        taskID = ""
        taskTitle = ""
    }

    init(listID: String, taskID: String, taskTitle: String) {
        self.listID = listID
        self.taskID = taskID
        self.taskTitle = taskTitle
    }

    func perform() async throws -> some IntentResult {
        let store = TaskWidgetSnapshotStore()
        let keychain = KeychainService(accessGroup: SharedConstants.keychainAccessGroup)
        let api = GoogleTasksAPI(tokenProvider: WidgetGoogleAccessTokenProvider())

        let outcome = await TaskWidgetCompletionCoordinator.complete(
            listID: listID,
            taskID: taskID,
            store: store,
            keychain: keychain,
            api: api
        )

        // Only after the coordinated write actually commits something.
        if outcome.sharedStateChanged {
            WidgetCenter.shared.reloadTimelines(ofKind: TaskWidgetConstants.widgetKind)
            TaskWidgetChangeSignal().post()
        }

        switch outcome.result {
        case .success:
            return .result()
        case .partialFailure, .transientFailure, .authFailure, .taskNotInList:
            throw CompleteTaskIntentError.notCompleted
        }
    }
}

/// Presented by the system when `CompleteTaskIntent.perform()` throws.
enum CompleteTaskIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notCompleted

    var localizedStringResource: LocalizedStringResource {
        "Couldn't complete this task. Open TaskMenu to try again."
    }
}
