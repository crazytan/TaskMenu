import SwiftUI

@main
struct TaskMenuApp: App {
    @State private var appState = AppState()

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
