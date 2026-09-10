import Foundation
import Testing
@testable import PocketdKit

/// The switch in Settings says what the user wants. What the engine hands the
/// model is this. They were the same thing until a 1B model replied to "what is
/// on my calendar" with the schema of `get_calendar_events`.
@Suite("Tool gate")
struct ToolGateTests {

    /// Llama 3.2's template, cut down to the parts either test can read. Both
    /// sizes ship this byte for byte, which is the whole difficulty.
    private static let llamaTemplate = """
    {%- if not tools_in_user_message is defined %}{%- set tools_in_user_message = true %}{%- endif %}
    {%- if tools is not none %}{{- "Given the following functions" }}{%- endif %}
    {%- elif 'tool_calls' in message %}{{- '{"name": "' + tool_call.name + '", "parameters": ' }}
    """
    /// SmolLM2's, in full. 369 characters with no idea of a tool in them.
    private static let chatMLTemplate = """
    {% for message in messages %}{{'<|im_start|>' + message['role'] + '\\n' + message['content'] + '<|im_end|>'}}{% endfor %}
    """

    private static func record(
        id: String,
        parameters: String = "—",
        toolSupport: ModelCapabilities.Support = .unknown
    ) -> ModelRecord {
        ModelRecord(
            id: id,
            displayName: id,
            repoID: "test/\(id)",
            filename: "\(id).gguf",
            parameters: parameters,
            quantization: "Q4_K_M",
            sizeBytes: 1_000,
            contextLength: 4096,
            license: "test",
            toolSupport: toolSupport
        )
    }

    @Test("a model declared incapable is never given tools, whatever its template says")
    func declaredNoWins() {
        // The template here is the tool-native one on purpose: `.no` is a
        // human's answer and it has to outrank the file's.
        let decision = ToolGate.decide(
            model: Self.record(id: "smolvlm-500m", parameters: "500M", toolSupport: .no),
            chatTemplate: Self.llamaTemplate,
            sizeLabel: "70B"
        )
        #expect(decision == .declaredIncapable)
        #expect(decision.registersTools == false)
    }

    @Test("the catalogue's declaration beats a stale one frozen into the manifest")
    func catalogueBeatsManifest() {
        // ModelStore writes the whole record to disk at download time and reads
        // it back for ever after, so a phone that downloaded Llama 3.2 1B
        // before this gate existed still has `toolSupport: unknown` on disk —
        // and the HTTP server loads models straight from that manifest.
        var stale = Self.record(id: "llama-3.2-1b", parameters: "1B", toolSupport: .unknown)
        stale.displayName = "Llama 3.2 1B"
        #expect(ToolGate.declaredSupport(for: stale) == .no)
        #expect(ToolGate.decide(model: stale, chatTemplate: Self.llamaTemplate, sizeLabel: "1B")
            == .declaredIncapable)
    }

    @Test("an unknown model with no notion of tools in its template is refused")
    func unknownWithoutToolTemplate() {
        let decision = ToolGate.decide(
            model: Self.record(id: "custom", parameters: "7B"),
            chatTemplate: Self.chatMLTemplate,
            sizeLabel: "7B"
        )
        #expect(decision == .templateHasNoTools)
    }

    @Test("an unknown model that is big enough and tool-native is allowed")
    func unknownInferred() {
        // The case that matters for anything added through search:
        // HuggingFaceSearch.record always writes `.unknown`, so refusing every
        // unknown would make every custom model toolless for ever.
        let decision = ToolGate.decide(
            model: Self.record(id: "someone-qwen3-8b"),
            chatTemplate: Self.llamaTemplate,
            sizeLabel: "8B"
        )
        #expect(decision == .inferredCapable)
        #expect(decision.registersTools)
    }

    @Test("size is what separates two models that ship the same template")
    func sizeIsTheOnlyAxis() {
        // Llama 3.2 1B and 3B are byte-identical here, which is why the
        // template cannot be the whole test.
        let small = ToolGate.decide(
            model: Self.record(id: "someone-llama-1b"),
            chatTemplate: Self.llamaTemplate,
            sizeLabel: "1B"
        )
        let large = ToolGate.decide(
            model: Self.record(id: "someone-llama-3b"),
            chatTemplate: Self.llamaTemplate,
            sizeLabel: "3B"
        )
        #expect(small == .tooSmall(billions: 1.0))
        #expect(small.registersTools == false)
        #expect(large == .inferredCapable)
    }

    @Test("an unreadable header registers nothing")
    func unreadableFailsClosed() {
        // The context guard reads a missing template as "assume the expensive
        // answer" and over-reserves. Reading the same silence as "assume it
        // works" here is how the schema reaches the user.
        let decision = ToolGate.decide(model: Self.record(id: "custom"), chatTemplate: nil, sizeLabel: nil)
        #expect(decision == .unreadable)
        #expect(decision.registersTools == false)
    }

    @Test("no resident model registers nothing and says so differently")
    func noModel() {
        let decision = ToolGate.decide(model: nil, chatTemplate: nil, sizeLabel: nil)
        #expect(decision == .noModelLoaded)
        #expect(decision.registersTools == false)
        // Not a refusal — nothing has refused anything yet, and colouring this
        // as a warning would make an empty Models tab look like a fault.
        #expect(decision.isRefusal == false)
    }

    @Test("a missing size label falls back to the catalogue's figure")
    func fallsBackToRecord() {
        // `general.size_label` is conventional, not guaranteed. A catalogue
        // entry still carries a hand-written one.
        let decision = ToolGate.decide(
            model: Self.record(id: "curated", parameters: "1B"),
            chatTemplate: Self.llamaTemplate,
            sizeLabel: nil
        )
        #expect(decision == .tooSmall(billions: 1.0))
    }

    @Test("a size nobody knows is allowed, because absent is not small")
    func unknownSizeIsAllowed() {
        // HuggingFaceSearch writes an em dash into `parameters`, and a GGUF
        // need not carry a size label. The template has already argued yes and
        // there is nothing left to argue no; ToolSyntaxScreen is what covers
        // the case where that judgement turns out wrong.
        let decision = ToolGate.decide(
            model: Self.record(id: "custom", parameters: "—"),
            chatTemplate: Self.llamaTemplate,
            sizeLabel: nil
        )
        #expect(decision == .inferredCapable)
    }

    @Test("every case names the model, the working one included")
    func explanations() {
        // The working case says so out loud. "On" and "working" looked
        // identical before, and that is the whole complaint.
        #expect(ToolGate.Decision.declaredCapable.explanation(modelName: "Qwen3 1.7B")?
            .contains("Qwen3 1.7B") == true)
        #expect(ToolGate.Decision.declaredCapable.isRefusal == false)
        for decision: ToolGate.Decision in [
            .declaredIncapable, .templateHasNoTools, .tooSmall(billions: 1.0), .unreadable
        ] {
            let sentence = decision.explanation(modelName: "Llama 3.2 1B")
            #expect(sentence?.contains("Llama 3.2 1B") == true)
            #expect(decision.isRefusal)
        }
        #expect(ToolGate.Decision.inferredCapable.explanation(modelName: "Custom")?.contains("Custom") == true)
        #expect(ToolGate.Decision.inferredCapable.isRefusal == false)

        // Llama 3.2 1B is `.no` and its template is full of tool machinery, so
        // the two refusals must not share a sentence: blaming the template
        // there would be a lie anyone could check by reading the file.
        let declared = ToolGate.Decision.declaredIncapable.explanation(modelName: "Llama 3.2 1B")
        #expect(declared?.contains("chat template") == false)
        #expect(ToolGate.Decision.templateHasNoTools.explanation(modelName: "x")?.contains("chat template") == true)
    }
}

@Suite("Size labels")
struct SizeLabelTests {

    @Test("the labels real GGUF headers carry")
    func realLabels() {
        // Each of these was read out of a file in this app's catalogue.
        #expect(ToolGate.parameterCount(fromSizeLabel: "1B") == 1.0)
        #expect(ToolGate.parameterCount(fromSizeLabel: "3B") == 3.0)
        #expect(ToolGate.parameterCount(fromSizeLabel: "1.7B") == 1.7)
        #expect(ToolGate.parameterCount(fromSizeLabel: "4.6B") == 4.6)
        #expect(ToolGate.parameterCount(fromSizeLabel: "135M") == 0.135)
        #expect(ToolGate.parameterCount(fromSizeLabel: "360M") == 0.36)
        #expect(ToolGate.parameterCount(fromSizeLabel: "500M") == 0.5)
    }

    @Test("the catalogue's prose parses too")
    func prose() {
        #expect(ToolGate.parameterCount(fromSizeLabel: "2B effective") == 2.0)
        #expect(ToolGate.parameterCount(fromSizeLabel: "8 B") == 8.0)
    }

    @Test("a mixture-of-experts label reads low rather than wrong")
    func mixture() {
        // 7 is the expert size, not the 46.7B total. Understating errs toward
        // refusing, which is the safe direction for this number.
        #expect(ToolGate.parameterCount(fromSizeLabel: "8x7B") == 7.0)
    }

    @Test("nothing believable reads as nothing")
    func unusable() {
        #expect(ToolGate.parameterCount(fromSizeLabel: "—") == nil)
        #expect(ToolGate.parameterCount(fromSizeLabel: "") == nil)
        #expect(ToolGate.parameterCount(fromSizeLabel: "Q4_K_M") == nil)
        #expect(ToolGate.parameterCount(fromSizeLabel: "unknown") == nil)
    }
}

/// The catalogue is the one place a human takes responsibility for a model, so
/// what it claims is checked rather than trusted.
@Suite("Catalogue tool support")
struct CatalogueToolSupportTests {

    @Test("nothing small is claimed capable")
    func nothingSmallIsYes() {
        for model in ModelCatalog.all where model.toolSupport == .yes {
            guard let billions = ToolGate.parameterCount(fromSizeLabel: model.parameters) else {
                // Gemma 4 E2B's "2B effective" parses; anything that does not
                // has no business claiming `.yes` from a hand-written figure.
                Issue.record("\(model.id) claims tool support with an unparseable size")
                continue
            }
            #expect(billions > ToolGate.minimumParametersInBillions, "\(model.id)")
        }
    }

    @Test("the models observed to leak are marked so")
    func knownBadAreNo() {
        // Regression pins for the two defects that shipped. If someone
        // reinstates `.unknown` on Llama 3.2 1B, the gate falls back to the
        // file, its template passes, and only its size stops it — which is
        // exactly the reasoning nobody should have to rediscover.
        #expect(ModelCatalog.model(withID: "llama-3.2-1b")?.toolSupport == .no)
        #expect(ModelCatalog.model(withID: "smollm2-360m")?.toolSupport == .no)
        #expect(ModelCatalog.model(withID: "smolvlm-500m")?.toolSupport == .no)
        #expect(ModelCatalog.model(withID: "gemma-3-4b-vision")?.toolSupport == .no)
    }

    @Test("every entry has been thought about")
    func noAccidentalUnknowns() {
        // `.unknown` is a legitimate answer, but only a deliberate one: the bug
        // was an entry that defaulted into it. This does not check the value,
        // it checks that the catalogue as a whole has not quietly grown a
        // majority of unexamined rows.
        let unknown = ModelCatalog.all.filter { $0.toolSupport == .unknown }
        #expect(unknown.count <= 1, "unexamined: \(unknown.map(\.id))")
    }
}
