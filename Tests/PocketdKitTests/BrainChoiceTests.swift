import Foundation
import Testing
@testable import PocketdKit

/// The choice between Apple's built-in brain and a downloaded one.
///
/// Every case below is a phone in a particular state — an upgrade from v1, a
/// restored backup on an older iPhone, Apple Intelligence switched off, a
/// downloaded brain removed — and what the app must do in it. The ones that
/// matter most are the ones where quietly doing something "helpful" would
/// switch somebody's brain without asking.
@Suite("Brain choice")
struct BrainChoiceTests {

    private func defaults() -> UserDefaults {
        let suite = "brain-choice-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func download(_ id: String, tools: ModelCapabilities.Support) -> ModelRecord {
        ModelRecord(
            id: id, displayName: id, repoID: "x/y", filename: "\(id).gguf",
            parameters: "1.7B", quantization: "Q4_K_M", sizeBytes: 1_100_000_000,
            contextLength: 4096, license: "Apache-2.0", toolSupport: tools
        )
    }

    // MARK: Persistence

    @Test("both kinds survive a round trip through defaults")
    func roundTrip() {
        let store = defaults()
        BrainChoice.builtIn.save(to: store)
        #expect(BrainChoice.load(from: store) == .builtIn)

        BrainChoice.downloaded(id: "qwen3-1.7b").save(to: store)
        #expect(BrainChoice.load(from: store) == .downloaded(id: "qwen3-1.7b"))
    }

    @Test("an id containing the separator is kept whole")
    func idWithColon() {
        #expect(BrainChoice(storedValue: "downloaded:owner-model:q4") == .downloaded(id: "owner-model:q4"))
    }

    @Test("values this build never wrote read as no choice, not a guess")
    func unreadableValues() {
        #expect(BrainChoice(storedValue: "") == nil)
        #expect(BrainChoice(storedValue: "downloaded:") == nil)
        #expect(BrainChoice(storedValue: "system") == nil)
        #expect(BrainChoice(storedValue: "BUILTIN") == nil)
    }

    @Test("an upgrade keeps the brain v1 was using, without writing anything")
    func legacyLoadedModel() {
        let store = defaults()
        store.set("qwen3-1.7b", forKey: "pocketd.loadedModel")
        #expect(BrainChoice.load(from: store) == .downloaded(id: "qwen3-1.7b"))
        #expect(store.string(forKey: BrainChoice.defaultsKey) == nil)
    }

    @Test("a stored choice outranks the legacy key")
    func storedWinsOverLegacy() {
        let store = defaults()
        store.set("qwen3-1.7b", forKey: "pocketd.loadedModel")
        BrainChoice.builtIn.save(to: store)
        #expect(BrainChoice.load(from: store) == .builtIn)
    }

    @Test("a fresh install has no choice")
    func freshInstall() {
        #expect(BrainChoice.load(from: defaults()) == nil)
    }

    @Test("the legacy key never reads back as the built-in brain's id")
    func legacyKeyHoldingBuiltInID() {
        let store = defaults()
        store.set(ModelRecord.builtInID, forKey: "pocketd.loadedModel")
        #expect(BrainChoice.load(from: store) == nil)
    }

    // MARK: Effective brain

    @Test("Apple Intelligence switched off keeps the built-in choice — the user can fix that")
    func turnedOffKeepsChoice() {
        for availability in [BuiltInBrainAvailability.turnedOff, .gettingReady, .available] {
            #expect(BrainChoice.effective(chosen: .builtIn, builtIn: availability, installed: ["qwen3-1.7b"]) == .builtIn)
        }
    }

    @Test("a phone that can never run the built-in brain falls back to a download, or to nothing")
    func notEligibleFallsBack() {
        for availability in [BuiltInBrainAvailability.notEligible, .unsupportedLanguage] {
            #expect(BrainChoice.effective(chosen: .builtIn, builtIn: availability, installed: ["qwen3-1.7b"]) == .downloaded(id: "qwen3-1.7b"))
            #expect(BrainChoice.effective(chosen: .builtIn, builtIn: availability, installed: []) == nil)
        }
    }

    @Test("only the states nobody can fix in Settings count as never answering")
    func canNeverAnswer() {
        #expect(BuiltInBrainAvailability.allCases.filter(\.canNeverAnswer) == [.unsupportedLanguage, .notEligible])
    }

    @Test("a removed download is replaced by the next installed one, then by the built-in brain")
    func removedDownload() {
        #expect(BrainChoice.effective(chosen: .downloaded(id: "gone"), builtIn: .available, installed: ["llama-3.2-1b"]) == .downloaded(id: "llama-3.2-1b"))
        #expect(BrainChoice.effective(chosen: .downloaded(id: "gone"), builtIn: .available, installed: []) == .builtIn)
        #expect(BrainChoice.effective(chosen: .downloaded(id: "gone"), builtIn: .turnedOff, installed: []) == nil)
    }

    @Test("an installed download stays chosen even when the built-in brain is ready")
    func downloadStaysChosen() {
        #expect(BrainChoice.effective(chosen: .downloaded(id: "qwen3-1.7b"), builtIn: .available, installed: ["qwen3-1.7b"]) == .downloaded(id: "qwen3-1.7b"))
    }

    @Test("no choice yet: the built-in brain when it is ready, else the first download")
    func noChoiceYet() {
        #expect(BrainChoice.effective(chosen: nil, builtIn: .available, installed: ["qwen3-1.7b"]) == .builtIn)
        #expect(BrainChoice.effective(chosen: nil, builtIn: .gettingReady, installed: ["qwen3-1.7b"]) == .downloaded(id: "qwen3-1.7b"))
        #expect(BrainChoice.effective(chosen: nil, builtIn: .turnedOff, installed: []) == nil)
    }

    // MARK: Recommendation

    @Test("the built-in brain is recommended whenever it is ready")
    func recommendsBuiltIn() {
        #expect(BrainChoice.recommended(builtIn: .available, download: download("qwen3-1.7b", tools: .yes)) == .builtIn)
        #expect(BrainChoice.recommended(builtIn: .available, download: nil) == .builtIn)
    }

    @Test("otherwise the download, but only one that can read the day")
    func recommendsOnlyToolCapableDownloads() {
        for availability in [BuiltInBrainAvailability.turnedOff, .gettingReady, .notEligible] {
            #expect(BrainChoice.recommended(builtIn: availability, download: download("qwen3-1.7b", tools: .yes)) == .downloaded(id: "qwen3-1.7b"))
            #expect(BrainChoice.recommended(builtIn: availability, download: download("smollm2-360m", tools: .no)) == nil)
            #expect(BrainChoice.recommended(builtIn: availability, download: download("mystery", tools: .unknown)) == nil)
            #expect(BrainChoice.recommended(builtIn: availability, download: nil) == nil)
        }
    }

    // MARK: Presentation

    @Test("each availability is worded as the Brain page spec says")
    func offers() {
        let ready = BuiltInBrainOffer.make(for: .available)
        #expect(ready.isListed && ready.canChoose)
        #expect(ready.detail == "Apple Intelligence · Nothing to download · Ready")

        let arriving = BuiltInBrainOffer.make(for: .gettingReady)
        #expect(arriving.isListed && arriving.canChoose)
        #expect(arriving.status == .gettingReady)

        let off = BuiltInBrainOffer.make(for: .turnedOff)
        #expect(!off.isListed)
        #expect(off.footnote == "Built-in AI isn't available on this iPhone.")
        #expect(off.settingsAction == "Turn on Apple Intelligence in Settings")

        let language = BuiltInBrainOffer.make(for: .unsupportedLanguage)
        #expect(!language.isListed && !language.canChoose)
        #expect(language.footnote == "Built-in AI doesn't speak your iPhone's language yet.")
        #expect(language.settingsAction == nil)

        let never = BuiltInBrainOffer.make(for: .notEligible)
        #expect(!never.isListed && never.footnote == nil && never.settingsAction == nil)
    }

    @Test("no copy names a model, a token or a network service")
    func copyHasNoMachinery() {
        let banned = ["token", "context", "model", "gguf", "openai", "chatgpt", "gpt", "foundationmodels", "llm"]
        var strings = [
            BuiltInBrainOffer.title, BuiltInBrainOffer.provider, BuiltInBrainOffer.onboardingDetail,
            BuiltInBrainOffer.readyDetail, BuiltInBrainOffer.gettingReadyDetail,
            BuiltInBrainOffer.unavailableFootnote, BuiltInBrainOffer.languageFootnote, BuiltInBrainOffer.turnOnAction
        ]
        strings += BuiltInBrainAvailability.allCases.map(BuiltInBrainOffer.rowStatus(for:))
        for string in strings {
            for word in banned {
                #expect(!string.lowercased().contains(word), "\"\(string)\" says \(word)")
            }
        }
    }

    // MARK: The residency record

    @Test("the built-in brain's id can never be a downloaded file's id")
    func builtInIDCannotCollide() {
        let downloaded = HuggingFaceSearch.identifier(repository: "system/apple-intelligence", filename: "x.gguf")
        #expect(downloaded != ModelRecord.builtInID)
        #expect(ModelRecord.builtInID.contains(":"))
        #expect(ModelRecord.builtIn.isBuiltInBrain)
        #expect(ModelRecord.builtIn.toolSupport.isYes)
        #expect(BrainChoice.builtIn.modelID == ModelRecord.builtInID)
        #expect(BrainChoice.downloaded(id: "qwen3-1.7b").modelID == "qwen3-1.7b")
    }
}
