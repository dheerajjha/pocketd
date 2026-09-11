import Foundation

/// What Settings says under the capability switches, decided in one place.
///
/// Three separate things can leave one of those switches on and inert, and each
/// of them holds its own sentence. `ToolGate` decides whether the resident model
/// is handed any tool at all. `CapabilityBudget` decides which of the tools it
/// was handed the context window can actually carry. `HealthAvailability`
/// decides whether there is a Health store on this device to read from.
///
/// Rendered side by side they contradicted each other: the gate says "both are
/// registered" the moment a model can work the tool protocol, and the budget is
/// free to refuse one of those two a line later for want of context — so a
/// 1,024-token window printed an assertion and its denial on the same screen,
/// the one screen someone opens to find out why their reminders are never read.
///
/// So the deciders are ranked here rather than in the view, and the rank is the
/// order they run in. A gate refusal means nothing was ever priced, so the
/// budget has nothing to add and the gate's sentence is the whole answer. Past
/// the gate, the budget is the thing that decided which capabilities exist, and
/// its sentence replaces the gate's blanket claim rather than sitting beneath
/// it — because only one of the two can be true and the later one is the one
/// that happened.
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
            return "Pocketd could not ask iOS for access to Health: \(reason)"
        }
    }
}
