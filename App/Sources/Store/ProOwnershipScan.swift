import PocketdKit
#if canImport(StoreKit)
import StoreKit

/// Keeps the old access verdict separate from certainty for analytics. An
/// unverified row grants nothing, but cannot prove that the account is free.
struct ProOwnershipScan {
    private(set) var ownsPurchase = false
    private(set) var hasUnverified = false
    private(set) var isComplete = false

    /// Only the end of currentEntitlements proves absence. A listener update,
    /// including a verified revocation, is not an enumeration of ownership.
    mutating func complete(cancelled: Bool = false) { isComplete = !cancelled }

    mutating func observe<Value>(_ result: VerificationResult<Value>, isCurrentPro: (Value) -> Bool) {
        switch result {
        case let .verified(value):
            if isCurrentPro(value) { ownsPurchase = true }
        case .unverified:
            hasUnverified = true
        }
    }

    func analyticsPlan(environment: ProAccess.StoreEnvironment?, originalAppVersion: String?,
                       cancelled: Bool = false) -> AnalyticsPlan {
        guard !cancelled else { return .unknown }
        if ownsPurchase { return .lifetime }
        if ProAccess.isEarlySupporter(environment: environment, originalAppVersion: originalAppVersion) {
            return .earlySupporter
        }
        return !isComplete || hasUnverified || environment == nil ? .unknown : .free
    }
}
#endif
