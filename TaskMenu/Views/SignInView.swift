import SwiftUI

struct SignInView: View {
    @Bindable var appState: AppState
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checklist")
                .font(.system(size: 40, weight: .thin))
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
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .onAppear {
            withAnimation(.easeOut(duration: 0.35)) {
                appeared = true
            }
        }
    }
}
