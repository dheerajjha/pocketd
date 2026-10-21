import Foundation
import LocalLLMClient
import PocketdKit

/// The engine behind the phone's own questions — the conversation, the brief
/// and routines — which is whichever brain the user chose.
///
/// One object rather than a choice re-made at every call site, because the
/// call sites are not all in one place: `ScheduleRunner` is handed its engine
/// once, at launch, and the chat and the brief each hold their own reference.
/// Forwarding here means a switch takes effect for all three at the same
/// moment, and none of them has to learn that two brains exist.
///
/// The server is not on this path. `InferenceServer` keeps `LlamaEngine`, so
/// other devices are served a downloaded brain whatever the phone is using, and
/// Apple's model never answers a network request.
actor PhoneBrain: InferenceEngine {
    /// The downloaded brain. Also the server's engine, and the built-in
    /// brain's fallback for a question Apple's model declines.
    let downloaded: LlamaEngine
    let builtIn: SystemModelEngine
    private var choice: BrainChoice?

    init(downloaded: LlamaEngine, builtIn: SystemModelEngine? = nil) {
        self.downloaded = downloaded
        self.builtIn = builtIn ?? SystemModelEngine(fallback: downloaded)
    }

    nonisolated var backendName: String { "phone" }

    /// Which brain answers from now on. `nil` (nothing chosen yet) answers
    /// with the downloaded brain, which is what the app did before there was a
    /// choice to make.
    ///
    /// Leaving the built-in brain stops whatever it is writing, the way
    /// switching downloaded brains does: an answer still streaming from the
    /// brain the user just left would arrive under the one they picked.
    func use(_ newChoice: BrainChoice?) async {
        guard newChoice != choice else { return }
        if choice == .builtIn { await builtIn.unload() }
        choice = newChoice
    }

    var current: BrainChoice? { choice }

    private var active: any InferenceEngine {
        choice == .builtIn ? builtIn : downloaded
    }

    // MARK: - InferenceEngine

    func loadedModel() async -> ModelRecord? { await active.loadedModel() }

    var promptOverheadTokens: Int {
        get async { await active.promptOverheadTokens }
    }

    var defaultSampling: SamplingParameters {
        get async { await active.defaultSampling }
    }

    /// Routed by the record, not by the choice: the built-in record can only
    /// ever be loaded into Apple's engine, and a GGUF only into llama.cpp.
    func load(model: ModelRecord) async throws {
        if model.isBuiltInBrain {
            try await builtIn.load(model: model)
        } else {
            try await downloaded.load(model: model)
        }
    }

    func unload() async { await active.unload() }

    func generate(_ request: GenerationRequest) async throws -> AsyncThrowingStream<GenerationEvent, any Error> {
        try await active.generate(request)
    }

    /// For a prompt that already carries every fact it may use — the daily
    /// brief. Apple's model gets no tools for it (see
    /// `SystemModelEngine.generate(_:toolsAllowed:)`); a downloaded brain
    /// answers exactly as `generate` would, because its tools are frozen into
    /// the loaded client and cannot be withheld per request.
    func generateWithoutTools(_ request: GenerationRequest) async throws -> AsyncThrowingStream<GenerationEvent, any Error> {
        if choice == .builtIn { return try await builtIn.generate(request, toolsAllowed: false) }
        return try await downloaded.generate(request)
    }

    // MARK: - What used to be LlamaEngine-only

    /// The active brain's verdict on reading the day. Apple's model always
    /// can; a downloaded one says what its chat template allows.
    var toolGate: ToolGate.Decision {
        get async {
            choice == .builtIn ? await builtIn.toolGate : await downloaded.toolGate
        }
    }

    /// Only a downloaded brain drops capabilities for space; the built-in
    /// brain trims history instead.
    var capabilityPlan: CapabilityBudget.Plan? {
        get async {
            choice == .builtIn ? await builtIn.capabilityPlan : await downloaded.capabilityPlan
        }
    }

    /// The ability switches, told to both brains at once.
    ///
    /// Both, always: the downloaded brain serves other devices and stands in
    /// when Apple's model declines, so it has to carry the current set whether
    /// or not the phone is talking to it.
    func updateAbilities(
        calendar: Bool,
        reminders: Bool,
        health: Bool,
        registrations: [(tool: any LLMTool, group: CapabilityGroup)],
        exempt: [any LLMTool] = []
    ) async {
        await downloaded.updateTools(registrations, exempt: exempt)
        await builtIn.updateAbilities(calendar: calendar, reminders: reminders, health: health)
    }
}
