import SwiftUI
import UIKit

@main
struct EddysWalletApp: App {
    @StateObject private var store: WalletStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        if let scenarioStore = DebugLaunchScenario.makeStore() {
            _store = StateObject(wrappedValue: scenarioStore)
            return
        }
        #endif
        // Production composition owns the guarded Cloud slice: one Cloud API
        // client over the keychain session, its StoreKit coordinator, and the
        // wallet store that may move authority only on a verified entitlement.
        let cloudClient = CloudAPIClient()
        _store = StateObject(wrappedValue: WalletStore(cloudCoordinator: CloudCoordinator(client: cloudClient)))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .tint(EW.Color.primaryActive)
                .onChange(of: scenePhase) { _, phase in
                    // Leaving the foreground always drops parent elevation and
                    // any in-progress parent flow. The kid home is the only
                    // state the app ever rests in.
                    if phase == .background {
                        store.handleAppBackgrounded()
                    }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: WalletStore

    var body: some View {
        Group {
            switch store.rootRoute {
            case .welcome:
                WelcomeView()
            case .setup:
                SetupView()
            case .kidHome:
                KidHomeView()
            case .recovery:
                WalletRecoveryView()
            }
        }
        .fullScreenCover(isPresented: isElevationPresented) {
            ElevationCoverView()
                .environmentObject(store)
        }
        .onChange(of: store.elevation) { oldValue, newValue in
            if newValue == .active {
                UIAccessibility.post(notification: .screenChanged, argument: "Parent area")
            } else if oldValue == .active, newValue == .none {
                UIAccessibility.post(
                    notification: .screenChanged,
                    argument: "Back in \(ChildProfileCopy.walletTitle(nickname: store.snapshot.configuredChildNickname))"
                )
            }
        }
        .preferredColorScheme(.light)
    }

    private var isElevationPresented: Binding<Bool> {
        Binding(
            get: { store.elevation != .none },
            set: { presented in
                guard !presented else { return }
                if store.elevation == .gate {
                    store.cancelParentGate()
                } else if store.elevation == .active {
                    store.exitParentArea()
                }
            }
        )
    }
}

/// Hosts the transient parent elevation: the PIN gate, then the Parent area.
/// Presented as one non-dismissable full-screen cover so that dropping
/// elevation always lands back on the kid home underneath.
struct ElevationCoverView: View {
    @EnvironmentObject private var store: WalletStore

    var body: some View {
        Group {
            if store.elevation == .active {
                ParentAreaView()
            } else {
                ParentGateView()
            }
        }
        .interactiveDismissDisabled()
    }
}
