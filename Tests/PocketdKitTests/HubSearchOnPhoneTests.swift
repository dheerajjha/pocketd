import Foundation
import Testing
@testable import PocketdKit

private func repo(_ id: String, downloads: Int = 1_000) -> HuggingFaceSearch.Repository {
    HuggingFaceSearch.Repository(id: id, downloads: downloads, likes: 0, gated: false)
}

private func phone(_ ram: Int, entitled: Bool = false) -> DeviceBudget {
    DeviceBudget(physicalMemoryBytes: Int64(ram) * 1024 * 1024 * 1024, hasIncreasedMemoryLimit: entitled, environment: .device)
}

@Suite("Hugging Face search on a phone")
struct HubSearchOnPhoneTests {

    @Test("repositories that advertise their safety training removed are not listed", arguments: [
        "mradermacher/Qwen3-8B-Uncensored-GGUF",
        "huihui-ai/Qwen3-4B-abliterated-GGUF",
        "someone/Llama-3.2-3B-NSFW-GGUF",
        "someone/Erotic-Writer-7B-GGUF",
    ])
    func blocked(id: String) {
        #expect(!HuggingFaceSearch.isListable(repo(id)))
    }

    @Test("speech, transcription, embedding, ranking and image repos are not brains", arguments: [
        // By name, whatever the hub says (or does not).
        ("Serveurperso/Qwen3-TTS-GGUF", "text-to-speech", nil),
        ("ggml-org/Qwen3-TTS-12Hz-1.7B-Base-GGUF", nil, nil),
        ("ggml-org/whisper.cpp", nil, nil),
        ("someone/parakeet-asr-GGUF", nil, nil),
        ("Qwen/Qwen3-Embedding-0.6B-GGUF", nil, ["feature-extraction"]),
        ("ggml-org/embeddinggemma-300M-GGUF", nil, nil),
        ("mixedbread-ai/mxbai-embed-large-v1", nil, nil),
        ("gpustack/bge-reranker-v2-m3-GGUF", nil, nil),
        ("someone/clip-vit-large-patch14-GGUF", nil, nil),
        ("someone/flux-vae-GGUF", nil, nil),
        ("second-state/stable-diffusion-v1-5-GGUF", nil, nil),
        ("gpustack/sd-turbo-GGUF", nil, nil),
        // An embedding model whose publisher tagged it text-generation.
        ("bartowski/granite-embedding-107m-multilingual-GGUF", "text-generation", nil),
        // By the hub's pipeline tag, when the name gives nothing away.
        ("christopherthompson81/MOSS-TTSD-GGUF", "text-to-speech", nil),
        ("someone/Parrot-Small-GGUF", "automatic-speech-recognition", nil),
        ("someone/Ranker-Small-GGUF", "text-ranking", nil),
        // By its tags, when there is no pipeline tag either.
        ("someone/Gemma-300M-GGUF", nil, ["feature-extraction", "sentence-similarity"]),
    ] as [(String, String?, [String]?)])
    func notChat(id: String, pipeline: String?, tags: [String]?) {
        let repository = HuggingFaceSearch.Repository(id: id, downloads: 1_000, likes: 0, gated: false, pipelineTag: pipeline, tags: tags)
        #expect(!HuggingFaceSearch.isChatModel(repository))
        #expect(!HuggingFaceSearch.isListable(repository))
    }

    @Test("chat models stay, vision chat included, and short words match only whole words", arguments: [
        ("Qwen/Qwen3-4B-GGUF", "text-generation", ["text-generation", "conversational"]),
        ("unsloth/Qwen3.5-4B-GGUF", "image-text-to-text", ["image-text-to-text", "conversational"]),
        ("lmstudio-community/Qwen3.5-9B-GGUF", nil, ["conversational"]),
        ("bartowski/Llama-3.2-3B-Instruct-GGUF", "text-generation", nil),
        ("someone/mystery-GGUF", nil, nil),
        ("someone/Kasra-7B-Chat-GGUF", "text-generation", nil),
        ("someone/Eclipse-3B-GGUF", "text-generation", nil),
    ] as [(String, String?, [String]?)])
    func chat(id: String, pipeline: String?, tags: [String]?) {
        let repository = HuggingFaceSearch.Repository(id: id, downloads: 1_000, likes: 0, gated: false, pipelineTag: pipeline, tags: tags)
        #expect(HuggingFaceSearch.isChatModel(repository))
        #expect(HuggingFaceSearch.isListable(repository))
    }

    @Test("QA's re-check: the speech model is gone from qwen3's results")
    func rankingDropsSpeech() {
        let results = [
            HuggingFaceSearch.Repository(id: "Serveurperso/Qwen3-TTS-GGUF", downloads: 485_134, likes: 0, gated: false, pipelineTag: "text-to-speech", tags: ["text-to-speech"]),
            HuggingFaceSearch.Repository(id: "unsloth/Qwen3-4B-GGUF", downloads: 506_648, likes: 0, gated: false, pipelineTag: "text-generation", tags: ["text-generation"]),
        ]
        #expect(HuggingFaceSearch.ranked(results, for: phone(8, entitled: true)).map(\.id) == ["unsloth/Qwen3-4B-GGUF"])
    }

    @Test("ordinary repositories are listed")
    func listed() {
        #expect(HuggingFaceSearch.isListable(repo("unsloth/Qwen3-1.7B-GGUF")))
        #expect(HuggingFaceSearch.isListable(repo("bartowski/Llama-3.2-3B-Instruct-GGUF")))
    }

    @Test("the size a name states", arguments: [
        ("Qwen3-32B-GGUF", 32.0),
        ("Qwen2.5-0.5B-Instruct-GGUF", 0.5),
        ("Qwen3-235B-A22B-GGUF", 235.0),
        ("Llama-3.2-1B-Instruct-GGUF", 1.0),
        ("gemma-3-4b-it-GGUF", 4.0),
        ("SmolLM2-360M-Instruct-GGUF", 0.36),
        ("Qwen3-1.7B-GGUF", 1.7),
    ])
    func stated(name: String, billions: Double) throws {
        let value = try #require(HuggingFaceSearch.statedBillions(in: name))
        #expect(abs(value - billions) < 0.0001)
    }

    @Test("no size, no guess", arguments: ["phi-GGUF", "Model-8bit-GGUF", "tiny-llm"])
    func unstated(name: String) {
        #expect(HuggingFaceSearch.statedBillions(in: name) == nil)
    }

    @Test("a repository too big at every useful size is called that before anyone opens it")
    func fitFromName() {
        let iPhone14 = phone(6)
        #expect(HuggingFaceSearch.fit(of: repo("Qwen/Qwen3-32B-GGUF"), for: iPhone14) == .willNotFit)
        #expect(HuggingFaceSearch.fit(of: repo("unsloth/Qwen3-1.7B-GGUF"), for: iPhone14) == .comfortable)
        #expect(HuggingFaceSearch.fit(of: repo("someone/mystery-GGUF"), for: iPhone14) == nil)
    }

    @Test("results: blocked and too-big gone, then fit, then popularity")
    func ranking() {
        let results = [
            repo("Qwen/Qwen3-32B-GGUF", downloads: 900_000),
            repo("huihui-ai/Qwen3-1.7B-abliterated-GGUF", downloads: 800_000),
            repo("someone/mystery-GGUF", downloads: 700_000),
            repo("unsloth/Qwen3-1.7B-GGUF", downloads: 50_000),
            repo("Qwen/Qwen3-0.6B-GGUF", downloads: 90_000),
            repo("unsloth/Qwen3-4B-GGUF", downloads: 600_000),
        ]
        let ranked = HuggingFaceSearch.ranked(results, for: phone(8, entitled: true)).map(\.id)
        #expect(!ranked.contains("Qwen/Qwen3-32B-GGUF"), "the 27B-and-up rows the walkthrough saw first")
        #expect(!ranked.contains("huihui-ai/Qwen3-1.7B-abliterated-GGUF"))
        #expect(ranked.first == "unsloth/Qwen3-4B-GGUF", "comfortable and the most downloaded of those")
        #expect(ranked.last == "someone/mystery-GGUF", "no stated size comes after every size that fits")
        #expect(ranked.firstIndex(of: "Qwen/Qwen3-0.6B-GGUF")! < ranked.firstIndex(of: "unsloth/Qwen3-1.7B-GGUF")!)
    }

    @Test("the sizes sheet: no projector, only what fits comfortably, smallest first")
    func fileOffers() {
        let files = [
            HuggingFaceSearch.File(path: "Qwen3-32B-Q4_K_M.gguf", sizeBytes: 19_800_000_000),
            HuggingFaceSearch.File(path: "mmproj-F16.gguf", sizeBytes: 941_300_000),
            HuggingFaceSearch.File(path: "Qwen3-1.7B-Q8_0.gguf", sizeBytes: 1_830_000_000),
            HuggingFaceSearch.File(path: "Qwen3-1.7B-Q4_K_M.gguf", sizeBytes: 1_107_409_472),
        ]
        // An iPhone 14 without the entitlement: the Q8_0 loads, but only just,
        // and an unchecked hub file that only just loads is not offered.
        let offers = HuggingFaceSearch.offers(files, for: phone(6))
        #expect(offers.map(\.file.path) == ["Qwen3-1.7B-Q4_K_M.gguf"])
        #expect(offers.allSatisfy { $0.isOffered && $0.fit == .comfortable && $0.tooBigNote == nil })

        let all = HuggingFaceSearch.offers(files, for: phone(6), includingTooBig: true)
        #expect(all.map(\.file.path) == ["Qwen3-1.7B-Q4_K_M.gguf", "Qwen3-1.7B-Q8_0.gguf", "Qwen3-32B-Q4_K_M.gguf"])
        #expect(all.dropFirst().allSatisfy { $0.tooBigNote == "Too big for this iPhone" })
        #expect(!all.contains { $0.file.isProjector })
        // With the entitlement the same phone has room for the Q8_0 as well.
        #expect(HuggingFaceSearch.offers(files, for: phone(6, entitled: true)).count == 2)
    }

    @Test("QA's search: 9B repos and 10 GB files are not offered on a phone, or on the simulator")
    func nineBillionIsTooBig() {
        let simulator = DeviceBudget(physicalMemoryBytes: 32 * 1024 * 1024 * 1024, hasIncreasedMemoryLimit: false, environment: .simulator)
        for budget in [phone(6), phone(8), phone(8, entitled: true), simulator] {
            #expect(HuggingFaceSearch.fit(of: repo("unsloth/Qwen3.5-9B-GGUF"), for: budget) == .willNotFit)
            let ranked = HuggingFaceSearch.ranked(
                [repo("unsloth/Qwen3.5-9B-GGUF", downloads: 1_300_000), repo("unsloth/Qwen3.5-4B-GGUF", downloads: 1_200_000),
                 repo("unsloth/Qwen3-1.7B-GGUF", downloads: 50_000)],
                for: budget
            ).map(\.id)
            #expect(!ranked.contains("unsloth/Qwen3.5-9B-GGUF"))
            #expect(ranked.last == "unsloth/Qwen3-1.7B-GGUF" || ranked.first == "unsloth/Qwen3-1.7B-GGUF")
            let tenGigabytes = HuggingFaceSearch.File(path: "Qwen3.5-9B-Q8_0.gguf", sizeBytes: 10_450_000_000)
            #expect(HuggingFaceSearch.offers([tenGigabytes], for: budget).isEmpty)
            #expect(HuggingFaceSearch.offers([tenGigabytes], for: budget, includingTooBig: true).first?.tooBigNote == "Too big for this iPhone")
        }
    }

    @Test("download counts read 64K, never 64L")
    func counts() {
        #expect(repo("a/b", downloads: 64_210).downloadsText == "64K")
        #expect(!repo("a/b", downloads: 6_400_000).downloadsText.contains("L"))
    }
}
