import Foundation

/// Whether the tools the user switched on are actually handed to the model.
///
/// This exists because registering a tool is not free and not harmless. The
/// library appends every schema to the system message of every prompt, so a
/// model that cannot use them pays for them on every question — and a model
/// small enough to be confused by them does something worse than ignore them.
/// Llama 3.2 1B, asked what was on the calendar, replied with the schema of
/// `get_calendar_events`: it had never seen the tool-calling protocol often
/// enough to recognise the schema as an instruction, so it copied what it saw
/// straight into the chat bubble. That is the failure this type prevents, and
/// the reason the answer is a gate rather than a badge on a listing.
///
/// The decision is a pure function of the record and the model's own GGUF
/// header so that it can be tested without weights, a simulator or a download,
/// which is the whole point of the `PocketdKit`/app split.
public enum ToolGate {

    /// The line below which a model is not given tools on inferred evidence, in
    /// billions of parameters. Strictly greater, so a 1B model is refused.
    ///
    /// Not a claim about what 1B models can do in general — it is where this
    /// app has watched the protocol break, and the break is loud rather than
    /// quiet. A model that merely fails to call the tool costs the user a
    /// feature; a model that echoes the schema costs them the reply as well.
    /// Only `.unknown` models are measured against it. A catalogue entry
    /// marked `.yes` is a human taking responsibility for a specific model and
    /// overrides this, which is what the catalogue is for.
    public static let minimumParametersInBillions = 1.0

    /// Why the resident model is or is not carrying the tools.
    ///
    /// Kept as reasons rather than a `Bool` because Settings has to say which
    /// model and why. A switch that is on and does nothing is worse than one
    /// that is off, and "off because Llama 3.2 1B cannot use them" is the only
    /// version of that sentence a user can act on.
    public enum Decision: Sendable, Equatable {
        /// The catalogue says this model was trained for tool calls.
        case declaredCapable
        /// The catalogue had no opinion, and the model's own file argued for
        /// it: a chat template with tool-call machinery, and enough parameters
        /// to be trusted with it.
        case inferredCapable
        /// The catalogue says no.
        case declaredIncapable
        /// Nothing declared, and the chat template has no notion of tools, so
        /// the model was never trained to emit a call.
        case templateHasNoTools
        /// Nothing declared, the template has the machinery, and the model is
        /// too small to work it. Carries what it was measured at.
        case tooSmall(billions: Double)
        /// Nothing declared and the header could not be read, so there is no
        /// evidence either way. Fails closed.
        case unreadable
        /// Nothing is resident, so there is nothing to decide about yet.
        case noModelLoaded

        /// The only thing the engine asks.
        public var registersTools: Bool {
            switch self {
            case .declaredCapable, .inferredCapable: return true
            case .declaredIncapable, .templateHasNoTools, .tooSmall, .unreadable, .noModelLoaded: return false
            }
        }
    }

    /// - Parameter chatTemplate: `tokenizer.chat_template` from the resident
    ///   model's GGUF, or `nil` when the header could not be read.
    /// - Parameter sizeLabel: `general.size_label` from the same header —
    ///   `"1B"`, `"1.7B"`, `"135M"`. Preferred over `ModelRecord.parameters`
    ///   because it is written by the file rather than by hand: the catalogue
    ///   calls Gemma 4 E2B "2B effective", which describes its compute, while
    ///   its own header says 4.6B. A searched Hugging Face model has no
    ///   hand-written figure at all.
    public static func decide(
        model: ModelRecord?,
        chatTemplate: String?,
        sizeLabel: String?
    ) -> Decision {
        guard let model else { return .noModelLoaded }

        switch declaredSupport(for: model) {
        case .yes: return .declaredCapable
        case .no: return .declaredIncapable
        case .unknown: break
        }

        // `.unknown` is neither "yes" nor "no", and answering it as either is
        // wrong in a way someone notices. Refusing makes every model added
        // through search toolless for ever, because `HuggingFaceSearch.record`
        // has no way to know and says so. Allowing is what shipped, and what
        // put a JSON schema in a chat bubble. So the model's own file is asked
        // instead — it is on the device by the time this matters, and it is
        // the only evidence that exists for a repository nobody has curated.
        guard let chatTemplate else { return .unreadable }

        // The primary evidence, and the same test the library itself applies
        // when it decides whether to inject schemas. A template with no notion
        // of tools describes a model that was never shown a tool call during
        // training, whatever its size.
        guard ContextGuard.templateIsToolNative(chatTemplate) else { return .templateHasNoTools }

        // Secondary, and only a filter: Llama 3.2 1B and 3B ship the same
        // template, character for character, so nothing in the template can
        // separate the one that works from the one that echoes it back. Size
        // is the only axis that can.
        //
        // A missing size is treated as passing rather than failing, because it
        // is an absent fact rather than a small number, and the primary
        // evidence has already argued yes. `ToolSyntaxScreen` is what stops
        // that judgement being visible to the user when it turns out wrong.
        guard let billions = parameterCount(fromSizeLabel: sizeLabel ?? model.parameters) else {
            return .inferredCapable
        }
        guard billions > minimumParametersInBillions else { return .tooSmall(billions: billions) }
        return .inferredCapable
    }

    /// The catalogue's word about a model, in preference to the record's own.
    ///
    /// `ModelStore` writes the whole `ModelRecord` into its manifest at
    /// download time and reads it back for ever after, so a model downloaded
    /// before this file existed carries `toolSupport: "unknown"` on disk no
    /// matter what the catalogue says today — and the HTTP server loads models
    /// straight from that manifest. Reading the declaration through the
    /// catalogue is what makes a correction here reach a phone that already
    /// has the weights.
    public static func declaredSupport(for model: ModelRecord) -> ModelCapabilities.Support {
        ModelCatalog.model(withID: model.id)?.toolSupport ?? model.toolSupport
    }

    /// Billions of parameters from a size label, or `nil` if there is no number
    /// in it to believe.
    ///
    /// Deliberately lenient about what surrounds the number: it has to cope
    /// with `general.size_label` (`"1.7B"`, `"135M"`), with the catalogue's
    /// prose (`"2B effective"`) and with the em dash `HuggingFaceSearch` writes
    /// when it does not know. A mixture-of-experts label like `"8x7B"` reads as
    /// 7 — the expert size, not the total — which understates and therefore
    /// errs toward refusing, the safe direction here.
    public static func parameterCount(fromSizeLabel label: String) -> Double? {
        let characters = Array(label)
        var index = 0
        while index < characters.count {
            guard characters[index].isNumber else {
                index += 1
                continue
            }
            var end = index
            while end < characters.count, characters[end].isNumber || characters[end] == "." {
                end += 1
            }
            defer { index = end }
            guard let value = Double(String(characters[index..<end])) else { continue }
            var unit = end
            while unit < characters.count, characters[unit] == " " { unit += 1 }
            guard unit < characters.count else { continue }
            switch characters[unit] {
            case "B", "b": return value
            case "M", "m": return value / 1000
            default: continue
            }
        }
        return nil
    }
}

public extension ToolGate.Decision {
    /// What Settings shows under the switch, naming the model.
    ///
    /// Every case names the model, the working one included. The switch is
    /// global and the answer is not — the same switch is live for Qwen3 1.7B
    /// and inert for Llama 3.2 1B — and the shipped bug was precisely that
    /// nothing distinguished the two. Saying nothing when it works would leave
    /// "on" and "working" looking identical again, which is the state this row
    /// exists to end.
    func explanation(modelName: String) -> String? {
        switch self {
        case .declaredCapable:
            return "\(modelName) can use these tools, and both are registered."
        case .inferredCapable:
            return "\(modelName) has not been checked for tool calling, but its own chat template describes tool calls, so both tools are registered."
        case .declaredIncapable:
            // Deliberately not the template sentence below. Llama 3.2 1B is
            // marked incapable and its template is full of tool machinery — it
            // simply cannot work the protocol — so blaming the template here
            // would be a plausible, checkable lie.
            return "\(modelName) is not able to use these tools, so nothing is registered and no context is spent on them. A 3B model or larger can."
        case .templateHasNoTools:
            return "\(modelName) cannot use these tools — its chat template has no notion of them — so nothing is registered and no context is spent on them."
        case .tooSmall:
            return "\(modelName) is too small to use these tools reliably, so nothing is registered and no context is spent on them. A 3B model or larger can."
        case .unreadable:
            return "\(modelName) could not be read closely enough to tell whether it can use these tools, so nothing is registered."
        case .noModelLoaded:
            return "No model is loaded, so nothing is registered yet. Whether the tools are used depends on which model you load."
        }
    }

    /// Whether the sentence above is a warning rather than a note.
    var isRefusal: Bool { !registersTools && self != .noModelLoaded }
}
