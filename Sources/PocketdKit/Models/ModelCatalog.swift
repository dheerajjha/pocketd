import Foundation

/// The curated list of models known to run on a phone.
///
/// This is intentionally short. An open catalogue of every GGUF on Hugging Face
/// is a worse experience on a 6 GB device than ten models that are known to
/// load, because the failure mode of the former is a 3 GB download that ends in
/// a jetsam kill. Arbitrary repositories are still reachable — through the `+`
/// on the Models tab, or `POST /api/models/add` from a laptop — they just are
/// not recommended.
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
            license: "Gemma Terms of Use"
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
            license: "Llama 3.2 Community"
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
            license: "Llama 3.2 Community"
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
            projectorSizeBytes: 851_251_104
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
            // Plain ChatML, 368 characters, no mention of tools anywhere.
            toolSupport: .no
        )
    ]

    public static func model(withID id: String) -> ModelRecord? {
        all.first { $0.id == id }
    }
}
