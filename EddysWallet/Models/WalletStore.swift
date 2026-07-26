import Combine
import Foundation

@MainActor
public final class WalletStore: ObservableObject {
    @Published public private(set) var snapshot: WalletSnapshot
    @Published public private(set) var role: UserRole = .parent
    @Published public private(set) var isSignedIn = false
    @Published public var isShowingPinGate = false
    @Published public private(set) var pin = ""
    @Published public private(set) var pinError = false

    public let repository: any WalletRepository
    private let parentPIN = "1234"

    public init(repository: (any WalletRepository)? = nil) {
        let resolvedRepository = repository ?? MockWalletRepository()
        self.repository = resolvedRepository
        self.snapshot = resolvedRepository.snapshot()
    }

    public func signInWithAppleIntegrationPoint() {
        isSignedIn = true
    }

    public func switchRole(to nextRole: UserRole) {
        guard nextRole != role else { return }
        if nextRole == .parent {
            pin = ""
            pinError = false
            isShowingPinGate = true
        } else {
            role = .child
        }
    }

    public func appendPINDigit(_ digit: String) {
        guard digit.count == 1, digit.first?.isNumber == true, pin.count < 4 else { return }
        pin.append(digit)
        pinError = false
        if pin.count == 4 {
            if pin == parentPIN {
                role = .parent
                isShowingPinGate = false
                pin = ""
            } else {
                pinError = true
                pin = ""
            }
        }
    }

    public func deletePINDigit() {
        guard !pin.isEmpty else { return }
        pin.removeLast()
        pinError = false
    }

    public func dismissPinGate() {
        isShowingPinGate = false
        pin = ""
        pinError = false
    }

    @discardableResult
    public func submit(_ command: WalletCommand) -> CommandResult {
        guard role == .parent else {
            let event = WalletEvent(
                type: .deposit,
                amountCents: command.amountCents,
                syncState: .rejected,
                explanation: "Eddie's view is read-only. This action was not recorded.",
                rejectionReason: "Only parent mode can record virtual money events."
            )
            return .rejected(event)
        }
        let result = repository.submit(command)
        snapshot = repository.snapshot()
        return result
    }

    public func signOut() {
        isSignedIn = false
        role = .parent
        dismissPinGate()
    }
}
