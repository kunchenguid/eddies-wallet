import Foundation

/// Local, privacy-safe Cloud recovery evidence.
///
/// It records only aggregate per-surface outcome counts and outcome classes so
/// an internal build can show what StoreKit recovery actually observed. The
/// model has no field that can hold a signed payload, receipt, transaction or
/// original-transaction identifier, account value, app account token, session
/// or auth value, correlation id, wallet/family/child data, or a raw StoreKit
/// error, and it never persists or leaves the device.
public struct CloudRecoveryEvidence: Codable, Equatable, Sendable {
    /// The passive StoreKit discovery surfaces available at the app's iOS 17
    /// deployment target, in the order recovery consults them, followed by the
    /// two long-lived streams.
    public enum Surface: String, CaseIterable, Codable, Equatable, Sendable {
        case currentEntitlements
        case latestTransaction
        case transactionHistory
        case subscriptionStatus
        case unfinished
        case transactionUpdates
    }

    /// Which bounded scan phase produced a surface readout.
    public enum ScanPhase: String, Codable, Equatable, Sendable {
        /// A passive sweep: launch recovery or a StoreKit-failure fallback.
        case passive
        /// The sweep immediately after a successful explicit Restore sync.
        case immediate
        /// The single bounded rescan after an empty immediate sweep.
        case delayed
    }

    /// How an explicit Restore's `AppStore.sync()` ended. Recorded only after
    /// the explicit parent action; the app never syncs automatically.
    public enum SyncOutcome: String, Codable, Equatable, Sendable {
        case returned
        case threw
    }

    /// The last delivery outcome class. `notAttempted` means no verified Cloud
    /// transaction was ever found to deliver.
    public enum DeliveryOutcome: String, Codable, Equatable, Sendable {
        case notAttempted
        /// The backend projection grants Cloud.
        case active
        /// Delivered, but the backend projection does not grant Cloud
        /// (expired, refunded, revoked, or billing retry).
        case inactive
        case pending
        case rejected
        case network
    }

    public struct SurfaceReadout: Codable, Equatable, Sendable {
        public var verifiedCloud: Int
        public var unverified: Int
        public var phase: ScanPhase
        public var at: Date

        public init(verifiedCloud: Int, unverified: Int, phase: ScanPhase, at: Date) {
            self.verifiedCloud = verifiedCloud
            self.unverified = unverified
            self.phase = phase
            self.at = at
        }
    }

    public private(set) var surfaces: [Surface: SurfaceReadout]
    public private(set) var lastSyncOutcome: SyncOutcome?
    public private(set) var deliveryOutcome: DeliveryOutcome
    /// Marketing version and build, for example "0.1.7 (9)": the only context
    /// kept, so separate scans on separate builds can be told apart.
    public let buildContext: String

    public init(buildContext: String = CloudRecoveryEvidence.currentBuildContext()) {
        surfaces = [:]
        lastSyncOutcome = nil
        deliveryOutcome = .notAttempted
        self.buildContext = buildContext
    }

    public static func currentBuildContext() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        return "\(version) (\(build))"
    }

    mutating func recordScan(surface: Surface, phase: ScanPhase, verifiedCloud: Int, unverified: Int, at: Date = .now) {
        surfaces[surface] = SurfaceReadout(verifiedCloud: verifiedCloud, unverified: unverified, phase: phase, at: at)
    }

    /// Long-lived streams have no scan boundary, so their sightings aggregate
    /// as running totals since launch.
    mutating func recordStreamSighting(surface: Surface, verified: Bool, at: Date = .now) {
        var readout = surfaces[surface] ?? SurfaceReadout(verifiedCloud: 0, unverified: 0, phase: .passive, at: at)
        if verified {
            readout.verifiedCloud += 1
        } else {
            readout.unverified += 1
        }
        readout.at = at
        surfaces[surface] = readout
    }

    mutating func recordSync(_ outcome: SyncOutcome) {
        lastSyncOutcome = outcome
    }

    mutating func recordDelivery(_ outcome: DeliveryOutcome) {
        deliveryOutcome = outcome
    }
}

/// One display row of the local evidence readout: a fixed title plus a value
/// assembled only from counts, class words, the scan phase, and a coarse time.
public struct CloudRecoveryEvidenceRow: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let value: String
    public let detail: String?

    public init(id: String, title: String, value: String, detail: String?) {
        self.id = id
        self.title = title
        self.value = value
        self.detail = detail
    }
}

extension CloudRecoveryEvidence {
    /// The exact content the Release-visible readout renders. Keeping the
    /// derivation here lets tests prove no sensitive value can appear on it.
    public var displayRows: [CloudRecoveryEvidenceRow] {
        var rows = [
            CloudRecoveryEvidenceRow(id: "build", title: "Build", value: buildContext, detail: nil),
            CloudRecoveryEvidenceRow(
                id: "sync",
                title: "Restore sync",
                value: lastSyncOutcome?.displayName ?? "not run",
                detail: "Runs only when you tap Restore purchase."
            ),
        ]
        for surface in Surface.allCases {
            rows.append(surfaceRow(surface))
        }
        rows.append(CloudRecoveryEvidenceRow(id: "delivery", title: "Delivery", value: deliveryOutcome.displayName, detail: nil))
        return rows
    }

    private func surfaceRow(_ surface: Surface) -> CloudRecoveryEvidenceRow {
        guard let readout = surfaces[surface] else {
            return CloudRecoveryEvidenceRow(id: surface.rawValue, title: surface.displayName, value: "not scanned", detail: nil)
        }
        let summary: String
        if readout.verifiedCloud == 0, readout.unverified == 0 {
            summary = "empty"
        } else if readout.unverified == 0 {
            summary = "\(readout.verifiedCloud) verified"
        } else {
            summary = "\(readout.verifiedCloud) verified, \(readout.unverified) unverified"
        }
        return CloudRecoveryEvidenceRow(
            id: surface.rawValue,
            title: surface.displayName,
            value: summary,
            detail: "\(readout.phase.displayName) · \(readout.at.formatted(date: .omitted, time: .standard))"
        )
    }
}

private extension CloudRecoveryEvidence.Surface {
    var displayName: String {
        switch self {
        case .currentEntitlements: "Current entitlements"
        case .latestTransaction: "Latest transaction per plan"
        case .transactionHistory: "Transaction history"
        case .subscriptionStatus: "Subscription status"
        case .unfinished: "Unfinished transactions"
        case .transactionUpdates: "Transaction updates"
        }
    }
}

private extension CloudRecoveryEvidence.ScanPhase {
    var displayName: String {
        switch self {
        case .passive: "passive scan"
        case .immediate: "just after Restore"
        case .delayed: "delayed rescan"
        }
    }
}

private extension CloudRecoveryEvidence.SyncOutcome {
    var displayName: String {
        switch self {
        case .returned: "returned"
        case .threw: "threw"
        }
    }
}

private extension CloudRecoveryEvidence.DeliveryOutcome {
    var displayName: String {
        switch self {
        case .notAttempted: "not attempted"
        case .active: "active"
        case .inactive: "plan not active"
        case .pending: "pending"
        case .rejected: "rejected"
        case .network: "network or unknown"
        }
    }
}
