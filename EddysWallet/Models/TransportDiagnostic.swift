import Foundation

/// What the newest wallet read could reach.
///
/// Only a device that genuinely reported no usable network is offline. Every
/// other authority the app failed to reach - a timeout, a TLS failure, a DNS
/// failure, a refused or dropped connection - is a service this app could not
/// reach on a device that is otherwise online. Collapsing the two was the
/// defect: it told a family on working WiFi that they were offline, and it
/// discarded the only evidence of what actually broke.
public enum WalletConnection: String, Equatable, Sendable, CaseIterable {
    /// The newest read reached its authority.
    case reached
    /// The device itself reported no usable network connection.
    case deviceOffline
    /// The device has a network connection; the wallet service could not be
    /// reached, or did not answer.
    case serviceUnreachable

    /// Whether the newest read actually reached its authority. Cloud money
    /// controls gate on this, so both failing states must answer `false`.
    public var reachedAuthority: Bool { self == .reached }
}

/// The privacy-safe shape of one wallet request that could not be used.
///
/// The client used to collapse every error `URLSession` threw into a single
/// "the network is unavailable" message, so a timeout, a TLS failure, a DNS
/// failure and a genuinely offline device all reached the kid home as
/// "You're offline". That was both false and unfixable: the one piece of
/// evidence that could name the real failure was discarded at the catch. This
/// type preserves that evidence in a form that is safe to keep and safe for a
/// parent to share when reporting the problem.
///
/// It carries only non-identifying shape: which class of failure the transport
/// reported, its raw numeric code, whether the system attached an underlying
/// error, which route was being read, the HTTP status when a response did
/// arrive, how long the attempt took, and when it ended. It has no field that
/// can hold an account, session or bearer value, wallet, family or child data,
/// a full URL, a query, an identifier, a request or response body, or a raw
/// error's user info - `route` is a normalised template, so a ledger entry or
/// loan id in a path cannot reach it either. Nothing here persists, and it
/// leaves the device only when a parent deliberately copies it.
public struct TransportDiagnostic: Equatable, Sendable {
    /// The class of failure, named the way the system names it. The `URLError`
    /// cases keep their exact Foundation spelling so a copied report can be
    /// matched against Apple's documentation and against a server log without
    /// a translation step.
    public enum Category: String, Equatable, Sendable, CaseIterable {
        // The device itself has no usable data path.
        case notConnectedToInternet
        case internationalRoamingOff
        case dataNotAllowed
        // The device has a data path; this request still could not complete.
        case timedOut
        case cannotConnectToHost
        case cannotFindHost
        case dnsLookupFailed
        case networkConnectionLost
        case secureConnectionFailed
        case serverCertificateUntrusted
        case serverCertificateHasBadDate
        case serverCertificateHasUnknownRoot
        case appTransportSecurityRequiresSecureConnection
        case badServerResponse
        /// A `URLError` this table does not name. `code` still identifies it
        /// exactly, so an unnamed failure is reported, never hidden.
        case otherURLError
        /// A thrown error that was not a `URLError` at all.
        case otherFailure
        /// The attempt was stopped before it could finish.
        case cancelled
        /// A response arrived and carried a failing HTTP status.
        case httpStatus
        /// A successful response arrived, but its body could not be decoded.
        case unreadableResponse

        /// What this failure proves about reaching the wallet's authority.
        ///
        /// `nil` means it proves nothing: a cancelled attempt observed no
        /// answer at all, so it must never change what the family is told.
        public var connection: WalletConnection? {
            switch self {
            case .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed:
                .deviceOffline
            case .cancelled:
                nil
            case .httpStatus, .unreadableResponse:
                // A status is an answer: the service was reached and replied.
                .reached
            case .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .networkConnectionLost, .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                 .appTransportSecurityRequiresSecureConnection, .badServerResponse,
                 .otherURLError, .otherFailure:
                .serviceUnreachable
            }
        }

        /// One plain sentence a parent can read, next to the exact name above.
        var explanation: String {
            switch self {
            case .notConnectedToInternet: "This device reported no internet connection."
            case .internationalRoamingOff: "Mobile data is turned off for roaming on this device."
            case .dataNotAllowed: "This device is not allowed to use mobile data right now."
            case .timedOut: "The service did not answer in time."
            case .cannotConnectToHost: "The connection to the service was refused."
            case .cannotFindHost: "The service's address could not be found."
            case .dnsLookupFailed: "Looking up the service's address failed."
            case .networkConnectionLost: "The connection dropped while the request was in flight."
            case .secureConnectionFailed: "The secure connection to the service failed."
            case .serverCertificateUntrusted: "The service's certificate was not trusted."
            case .serverCertificateHasBadDate: "The service's certificate is expired or not yet valid."
            case .serverCertificateHasUnknownRoot: "The service's certificate has an unknown root."
            case .appTransportSecurityRequiresSecureConnection: "The connection did not meet this app's security requirements."
            case .badServerResponse: "The service's reply could not be understood."
            case .otherURLError: "The system reported a network failure this app does not name."
            case .otherFailure: "The request failed for a reason outside the network layer."
            case .cancelled: "The request was stopped before it finished."
            case .httpStatus: "The service answered, and the answer was a failure."
            case .unreadableResponse: "The service answered, but this app could not read the answer."
            }
        }

        init(_ code: URLError.Code) {
            switch code {
            case .notConnectedToInternet: self = .notConnectedToInternet
            case .internationalRoamingOff: self = .internationalRoamingOff
            case .dataNotAllowed: self = .dataNotAllowed
            case .timedOut: self = .timedOut
            case .cannotConnectToHost: self = .cannotConnectToHost
            case .cannotFindHost: self = .cannotFindHost
            case .dnsLookupFailed: self = .dnsLookupFailed
            case .networkConnectionLost: self = .networkConnectionLost
            case .secureConnectionFailed: self = .secureConnectionFailed
            case .serverCertificateUntrusted: self = .serverCertificateUntrusted
            case .serverCertificateHasBadDate, .serverCertificateNotYetValid: self = .serverCertificateHasBadDate
            case .serverCertificateHasUnknownRoot: self = .serverCertificateHasUnknownRoot
            case .appTransportSecurityRequiresSecureConnection: self = .appTransportSecurityRequiresSecureConnection
            case .badServerResponse: self = .badServerResponse
            case .cancelled: self = .cancelled
            default: self = .otherURLError
            }
        }
    }

    /// One row of the parent-facing readout.
    public struct Row: Equatable, Identifiable, Sendable {
        public let id: String
        public let title: String
        public let value: String
        public let detail: String?

        public init(id: String, title: String, value: String, detail: String? = nil) {
            self.id = id
            self.title = title
            self.value = value
            self.detail = detail
        }
    }

    /// A monotonic stopwatch for one request attempt. Wall-clock time can jump
    /// while a request is in flight, which would report a nonsense elapsed
    /// value exactly when a slow request is the thing being measured.
    public struct Stopwatch: Sendable {
        private let start = DispatchTime.now()

        public init() {}

        public var elapsedMilliseconds: Int {
            Int((DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000)
        }
    }

    public let category: Category
    /// The system's raw numeric code, absent when the failure carried none.
    public let code: Int?
    /// Whether the system attached an underlying error. Only its presence is
    /// kept: an underlying error's own contents are never read or stored.
    public let hasUnderlyingError: Bool
    /// The route template that was being requested. Never a full URL, a query,
    /// or a concrete identifier.
    public let route: String
    /// The HTTP status, when a response arrived at all.
    public let httpStatus: Int?
    public let elapsedMilliseconds: Int
    /// When the attempt ended, so a parent's report can be lined up against a
    /// service log without naming the parent, the device, or the wallet.
    public let timestamp: Date

    public init(
        category: Category,
        code: Int?,
        hasUnderlyingError: Bool,
        route: String,
        httpStatus: Int?,
        elapsedMilliseconds: Int,
        timestamp: Date = .now
    ) {
        self.category = category
        self.code = code
        self.hasUnderlyingError = hasUnderlyingError
        self.route = Self.route(forPath: route)
        self.httpStatus = httpStatus
        self.elapsedMilliseconds = elapsedMilliseconds
        self.timestamp = timestamp
    }

    /// Preserves what the transport threw before any response arrived. This is
    /// the exact evidence the old blanket catch discarded.
    public static func transportFailure(
        _ error: Error,
        path: String,
        elapsedMilliseconds: Int,
        timestamp: Date = .now
    ) -> TransportDiagnostic {
        let category: Category
        let code: Int?
        if error is CancellationError {
            category = .cancelled
            code = nil
        } else if let urlError = error as? URLError {
            category = Category(urlError.code)
            code = urlError.errorCode
        } else {
            category = .otherFailure
            code = (error as NSError).code
        }
        return TransportDiagnostic(
            category: category,
            code: code,
            hasUnderlyingError: (error as NSError).userInfo[NSUnderlyingErrorKey] != nil,
            route: route(forPath: path),
            httpStatus: nil,
            elapsedMilliseconds: elapsedMilliseconds,
            timestamp: timestamp
        )
    }

    /// Records a response that arrived and carried a failing HTTP status. The
    /// status is the whole evidence; the body is never read here.
    public static func httpFailure(
        status: Int,
        path: String,
        elapsedMilliseconds: Int,
        timestamp: Date = .now
    ) -> TransportDiagnostic {
        TransportDiagnostic(
            category: .httpStatus,
            code: nil,
            hasUnderlyingError: false,
            route: route(forPath: path),
            httpStatus: status,
            elapsedMilliseconds: elapsedMilliseconds,
            timestamp: timestamp
        )
    }

    /// Records a successful response whose body could not be decoded. The
    /// status is the whole response evidence retained here; the body is never
    /// stored.
    public static func unreadableResponse(
        status: Int,
        path: String,
        elapsedMilliseconds: Int,
        timestamp: Date = .now
    ) -> TransportDiagnostic {
        TransportDiagnostic(
            category: .unreadableResponse,
            code: nil,
            hasUnderlyingError: false,
            route: route(forPath: path),
            httpStatus: status,
            elapsedMilliseconds: elapsedMilliseconds,
            timestamp: timestamp
        )
    }

    /// What this failure proves about reaching the wallet's authority, or
    /// `nil` when it proves nothing.
    public var connection: WalletConnection? { category.connection }

    /// Parent-facing sentence for the one error path that carries a
    /// diagnostic. Every branch keeps the existing "not changed" reassurance,
    /// because none of these failures can have moved money.
    var parentMessage: String {
        switch category.connection {
        case .deviceOffline:
            "There is no internet connection. The accepted balance was not changed."
        case .serviceUnreachable:
            "\(ProductBrand.displayName) could not be reached. The accepted balance was not changed."
        case .reached, .none:
            "That request did not finish. The accepted balance was not changed."
        }
    }

    /// The exact content the parent-facing readout renders. Keeping the
    /// derivation here lets a test prove that no sensitive value can appear on
    /// it, and lets the copy action below be built from the same rows so the
    /// copied text can never say more than the screen does.
    public var displayRows: [Row] {
        [
            Row(id: "category", title: "What failed", value: category.rawValue, detail: category.explanation),
            Row(id: "code", title: "Error code", value: code.map(String.init) ?? "none"),
            Row(id: "underlying", title: "Underlying error", value: hasUnderlyingError ? "present" : "absent"),
            Row(id: "route", title: "Route", value: route),
            Row(id: "status", title: "Response status", value: httpStatus.map(String.init) ?? "no response"),
            Row(id: "elapsed", title: "Took", value: "\(elapsedMilliseconds) ms"),
            Row(id: "timestamp", title: "When", value: timestamp.formatted(.iso8601)),
        ]
    }

    public static let summaryTitle = "\(ProductBrand.displayName) connection report"

    /// The plain text a parent copies. Assembled only from `displayRows`, so
    /// it can carry nothing the readout does not already show.
    public var shareableSummary: String {
        ([Self.summaryTitle] + displayRows.map { "\($0.title): \($0.value)" }).joined(separator: "\n")
    }

    /// Every route shape this client can request. Parameter positions are
    /// explicit, so an identifier is redacted even when its value happens to
    /// equal a fixed route component.
    private static let routeTemplates: [[String]] = [
        ["v1", "child-view"],
        ["v1", "wallet"],
        ["v1", "wallet", "deposits"],
        ["v1", "wallet", "withdrawals"],
        ["v1", "activity"],
        ["v1", "activity", "{id}"],
        ["v1", "loans"],
        ["v1", "loans", "{id}"],
        ["v1", "loans", "{id}", "repayments"],
        ["v1", "allowance-rule"],
        ["v1", "allowance-rule", "{id}", "occurrences", "{id}", "record"],
        ["v1", "family", "setup"],
        ["v1", "child"],
        ["v1", "auth", "apple"],
        ["v1", "capabilities"],
        ["v1", "cloud", "context"],
        ["v1", "cloud", "transactions"],
        ["v1", "cloud", "bootstrap"],
        ["v1", "cloud", "changes"],
        ["v1", "cloud", "household", "import"],
        ["v1", "cloud", "legacy-context"],
        ["v1", "cloud", "legacy-activate"],
        ["v1", "session", "current"],
        ["v1", "account"],
    ]

    /// Reduces a request path to a known route template after dropping its
    /// query and fragment. Unknown shapes are fully redacted rather than
    /// risking disclosure from a future parameter position.
    public static func route(forPath path: String) -> String {
        let withoutQuery = path.prefix { $0 != "?" && $0 != "#" }
        let components = withoutQuery
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !components.isEmpty else { return "/" }
        if let template = routeTemplates.first(where: { template in
            template.count == components.count && zip(template, components).allSatisfy { pair in
                pair.0 == "{id}" || pair.0 == pair.1
            }
        }) {
            return "/" + template.joined(separator: "/")
        }
        return "/" + components.map { _ in "{id}" }.joined(separator: "/")
    }
}
