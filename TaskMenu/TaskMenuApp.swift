import SwiftUI

@main
struct TaskMenuApp: App {
    @State private var appState: AppState

    init() {
        _appState = State(initialValue: AppState())
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover(appState: appState)
        } label: {
            Label("TaskMenu", systemImage: "checklist")
                .labelStyle(.iconOnly)
        }
        .menuBarExtraStyle(.window)
    }
}
