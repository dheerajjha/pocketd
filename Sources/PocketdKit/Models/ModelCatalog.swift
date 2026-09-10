import Foundation

/// The curated list of models known to run on a phone.
///
/// This is intentionally short. An open catalogue of every GGUF on Hugging Face
/// is a worse experience on a 6 GB device than ten models that are known to
/// load, because the failure mode of the former is a 3 GB download that ends in
/// a jetsam kill. Arbitrary repositories are still reachable — through the `+`
/// on the Models tab, or `POST /api/models/add` from a laptop — they just are
/// not recommended.
///
/// `toolSupport` on every entry below was decided by reading that entry's own
/// `tokenizer.chat_template` out of its GGUF header — locally where the file
/// was already downloaded, and over a ranged HTTP request for the rest, since
/// the header is at the front of the file. Nothing here is from memory. Where
/// a template has no notion of tools the answer is `.no` and the model is
/// never charged for a schema it cannot read; where it does, the answer turns
/// on whether the model is big enough to work the protocol, which is a
/// judgement and is written down as one on each entry.
public enum ModelCatalog {
    /// Every entry must be publicly downloadable without a token. A gated
    /// repository answers 401 from the API itself, which surfaced here as the
    /// first two rows of the list failing the moment anyone tapped them —
    /// Gemma 4's repo is gated, and Qwen's own repo does not publish the Q4 of
    /// that size at all. `scripts/verify-catalogue.sh` checks every URL.
    public static let all: [ModelRecord] = [
        // Gemma 4's edge variant. Note the size: E2B is a MatFormer, so "2B
        // effective parameters" describes the compute, not the weights — the
        // file carries the full nested model and is 3.1 GB at Q4_K_M, not the
        // ~1.8 GB the parameter count suggests. It therefore does NOT fit a
        // 6 GB iPhone even with the increased memory limit, and the fit badge
        // says so. Google's own GGUF repo does not exist under that name and
        // its other Gemma repos are gated, so this is unsloth's mirror.
        ModelRecord(
            id: "gemma-4-e2b",
            displayName: "Gemma 4 E2B",
            repoID: "unsloth/gemma-4-E2B-it-GGUF",
            filename: "gemma-4-E2B-it-Q4_K_M.gguf",
            parameters: "2B effective",
            quantization: "Q4_K_M",
            sizeBytes: 3_106_738_272,
            contextLength: 131_072,
            license: "Gemma Terms of Use",
            // An 18.8 KB template built around tool calls: `format_parameters`
            // and `format_function_declaration` macros that render a schema,
            // and a `<|tool_call>` … `<tool_call|>` pair for the model to
            // answer in. Its header also says 4.6B, where the row above says
            // "2B effective" — the latter is the compute, and the former is
            // what has to follow the protocol.
            toolSupport: .yes
        ),
        ModelRecord(
            id: "qwen3-1.7b",
            displayName: "Qwen3 1.7B",
            // Qwen's own repo publishes only Q8_0 of this size, so the
            // Q4_K_M comes from unsloth's mirror. Verified by scripts/verify-catalogue.sh.
            repoID: "unsloth/Qwen3-1.7B-GGUF",
            filename: "Qwen3-1.7B-Q4_K_M.gguf",
            parameters: "1.7B",
            quantization: "Q4_K_M",
            sizeBytes: 1_107_409_472,
            contextLength: 32_768,
            license: "Apache-2.0",
            // Tool-native template — a `# Tools` preamble, `<tools>` for the
            // schemas and `<tool_call>` for the answer — and the smallest model
            // in this catalogue observed to complete a calendar lookup end to
            // end on a simulator: it called `get_calendar_events`, read the
            // result back and answered in a sentence.
            toolSupport: .yes
        ),
        ModelRecord(
            id: "llama-3.2-1b",
            displayName: "Llama 3.2 1B",
            repoID: "bartowski/Llama-3.2-1B-Instruct-GGUF",
            filename: "Llama-3.2-1B-Instruct-Q4_K_M.gguf",
            parameters: "1B",
            quantization: "Q4_K_M",
            sizeBytes: 808_000_000,
            contextLength: 131_072,
            license: "Llama 3.2 Community",
            // `.no` from observation, not from the template — which is
            // byte-identical to the 3B's below and would pass any test based on
            // it. Asked what was on the calendar, this model replied with the
            // *schema* of `get_calendar_events`, formatted and complete, and
            // then invented Swift that indexed a dictionary of the other tools.
            // It is not failing to call the tool; it does not recognise the
            // schema in its prompt as anything but text to continue.
            toolSupport: .no
        ),
        ModelRecord(
            id: "llama-3.2-3b",
            displayName: "Llama 3.2 3B",
            repoID: "bartowski/Llama-3.2-3B-Instruct-GGUF",
            filename: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            parameters: "3B",
            quantization: "Q4_K_M",
            sizeBytes: 2_020_000_000,
            contextLength: 131_072,
            license: "Llama 3.2 Community",
            // Same template as the 1B, and it does not leak it. Left
            // `.unknown` rather than promoted to `.yes`: this size is the one
            // Meta documents for tool calling and the gate lets it through on
            // the file's own evidence, but "the model can be trusted with the
            // protocol" is a claim `.yes` makes on a human's behalf, and what
            // was watched here was one question answered, not a model that
            // holds up. Nothing about the user's experience differs; the
            // difference is who is on the hook for it.
            toolSupport: .unknown
        ),
        ModelRecord(
            id: "qwen3-4b",
            displayName: "Qwen3 4B",
            repoID: "Qwen/Qwen3-4B-GGUF",
            filename: "Qwen3-4B-Q4_K_M.gguf",
            parameters: "4B",
            quantization: "Q4_K_M",
            sizeBytes: 2_500_000_000,
            contextLength: 32_768,
            license: "Apache-2.0",
            // The same Qwen3 template as the 1.7B, on more than twice the
            // parameters. If the smaller one works, this one does.
            toolSupport: .yes
        ),
        // Vision. Sizes are the real Content-Length of both files; the
        // projector is resident alongside the weights, so it counts toward the
        // memory budget and the fit badge.
        ModelRecord(
            id: "smolvlm-500m",
            displayName: "SmolVLM 500M",
            repoID: "ggml-org/SmolVLM-500M-Instruct-GGUF",
            filename: "SmolVLM-500M-Instruct-Q8_0.gguf",
            parameters: "500M",
            quantization: "Q8_0",
            sizeBytes: 436_806_912,
            contextLength: 8_192,
            license: "Apache-2.0",
            projectorFilename: "mmproj-SmolVLM-500M-Instruct-Q8_0.gguf",
            projectorSizeBytes: 108_783_360,
            // A 404-character template that interleaves text and `<image>` and
            // has no other idea in it. Half a billion parameters besides.
            toolSupport: .no
        ),
        ModelRecord(
            id: "gemma-3-4b-vision",
            displayName: "Gemma 3 4B (vision)",
            repoID: "ggml-org/gemma-3-4b-it-GGUF",
            filename: "gemma-3-4b-it-Q4_K_M.gguf",
            parameters: "4B",
            quantization: "Q4_K_M",
            sizeBytes: 2_489_757_856,
            contextLength: 131_072,
            license: "Gemma Terms of Use",
            projectorFilename: "mmproj-model-f16.gguf",
            projectorSizeBytes: 851_251_104,
            // Big enough, and still `.no`: Gemma 3's template is 1.5 KB of
            // role markers and image handling with not one occurrence of the
            // word "tools". Gemma 3 does function calling by being asked to in
            // the system prompt, which is not the protocol this app speaks.
            // Its successor E2B above is a different template entirely.
            toolSupport: .no
        ),
        ModelRecord(
            id: "smollm2-360m",
            displayName: "SmolLM2 360M",
            repoID: "HuggingFaceTB/SmolLM2-360M-Instruct-GGUF",
            filename: "smollm2-360m-instruct-q8_0.gguf",
            parameters: "360M",
            quantization: "Q8_0",
            sizeBytes: 386_000_000,
            contextLength: 8_192,
            license: "Apache-2.0",
            // Plain ChatML, 369 characters, no mention of tools anywhere.
            toolSupport: .no
        )
    ]

    public static func model(withID id: String) -> ModelRecord? {
        all.first { $0.id == id }
    }
}
