import Foundation

/// The curated list of models known to run on a phone.
///
/// This is intentionally short. An open catalogue of every GGUF on Hugging Face
/// is a worse experience on a 6 GB device than ten models that are known to
/// load, because the failure mode of the former is a 3 GB download that ends in
/// a jetsam kill. Arbitrary repositories are still reachable through
/// `ModelStore.custom(repoID:filename:)`; they just are not recommended.
public enum ModelCatalog {
    public static let all: [ModelRecord] = [
        ModelRecord(
            id: "gemma-4-e2b",
            displayName: "Gemma 4 E2B",
            repoID: "google/gemma-4-E2B-it-GGUF",
            filename: "gemma-4-E2B-it-Q4_K_M.gguf",
            parameters: "2B (effective)",
            quantization: "Q4_K_M",
            sizeBytes: 1_800_000_000,
            contextLength: 131_072,
            license: "Gemma Terms of Use"
        ),
        ModelRecord(
            id: "qwen3-1.7b",
            displayName: "Qwen3 1.7B",
            repoID: "Qwen/Qwen3-1.7B-GGUF",
            filename: "Qwen3-1.7B-Q4_K_M.gguf",
            parameters: "1.7B",
            quantization: "Q4_K_M",
            sizeBytes: 1_100_000_000,
            contextLength: 32_768,
            license: "Apache-2.0"
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
            license: "Apache-2.0"
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
            projectorSizeBytes: 108_783_360
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
            license: "Apache-2.0"
        )
    ]

    public static func model(withID id: String) -> ModelRecord? {
        all.first { $0.id == id }
    }
}
