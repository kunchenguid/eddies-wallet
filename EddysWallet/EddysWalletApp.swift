import SwiftUI

@main
struct EddysWalletApp: App {
    @StateObject private var store = WalletStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .tint(EW.Color.primaryActive)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: WalletStore

    var body: some View {
        Group {
            if store.isSignedIn {
                WalletView()
            } else {
                WelcomeView()
            }
        }
        .preferredColorScheme(.light)
    }
}
