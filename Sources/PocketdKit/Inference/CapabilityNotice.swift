import Foundation

/// An explanation of the model's tool support or of a capability that did not fit.
///
/// The gate answers whether the model may be offered tools, not which apps are
/// connected. If it refuses, nothing is priced. If it allows tools but the
/// budget drops one, the budget explains the shortfall. Neither verdict reports
/// what permission iOS granted.
public struct CapabilityNotice: Sendable, Equatable {
    /// The sentence at the top of the section.
    public var summary: String
    /// Whether it is a warning rather than a note — something the reader can act
    /// on, as against a description of a switch that is working.
    public var isWarning: Bool
    /// One line per capability the window refused, each naming what it would
    /// cost and which context would carry it. Empty whenever `summary` came
    /// from the gate, because a gate refusal registers nothing and there is no
    /// per-capability price to quote.
    public var shortfalls: [String]

    public init(summary: String, isWarning: Bool, shortfalls: [String] = []) {
        self.summary = summary
        self.isWarning = isWarning
        self.shortfalls = shortfalls
    }

    /// - Parameter plan: What the budget did with what the gate allowed, or
    ///   `nil` when nothing was asked for — the switches are off, or the gate
    ///   refused before anything could be priced.
    /// - Parameter modelName: The resident model, named the way the user named
    ///   it when they loaded it.
    public static func decide(
        gate: ToolGate.Decision,
        plan: CapabilityBudget.Plan?,
        modelName: String
    ) -> CapabilityNotice? {
        guard let sentence = gate.explanation(modelName: modelName) else { return nil }
        guard gate.registersTools, let plan, let refusal = plan.explanation else {
            return CapabilityNotice(summary: sentence, isWarning: gate.isRefusal)
        }
        // Deliberately without the model's name, where every gate sentence
        // carries one. The window refused these, not the model — it would carry
        // them on the same weights at the next context tier up — and naming the
        // model here would send someone off to swap a model that was never what
        // refused them. `Dropped.explanation` names what to change instead.
        return CapabilityNotice(
            summary: refusal,
            isWarning: true,
            shortfalls: plan.dropped
                .filter { $0.reason == .overBudget }
                .map(\.explanation)
        )
    }
}

public extension HealthAvailability {
    /// What Settings shows under the health switch, or `nil` when there is
    /// nothing to say.
    ///
    /// Lives beside the other two deciders rather than with the readout type
    /// because it answers their question, not HealthKit's: why is this switch on
    /// and reading nothing. It is also the one of the three whose wording is
    /// constrained from outside — iOS never tells an app whether a *read* was
    /// granted or refused, so nothing here may imply the app knows which, and
    /// these sentences stay strictly about whether there is a store to talk to.
    /// `HealthSummary.ambiguityNote` sets that register for the model; this is
    /// the same register for the user.
    var explanation: String? {
        switch self {
        case .available:
            return nil
        case .noHealthData:
            return "Health data is not available on this device, so this switch has nothing to read."
        case .requestFailed(let reason):
            // Word for word what the tool would have told the model, so one
            // problem has one wording wherever it surfaces.
            return reason
        }
    }
}
