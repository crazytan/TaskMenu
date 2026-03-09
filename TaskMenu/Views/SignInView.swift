import SwiftUI

struct SignInView: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checklist")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("TaskMenu")
                .font(.title2.bold())

            Text("Sign in with Google to access your tasks.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(action: {
                appState.signIn()
            }) {
                Label("Sign in with Google", systemImage: "person.badge.key.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 320)
    }
}
