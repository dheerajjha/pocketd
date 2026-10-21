import Foundation

/// Which brain answers the phone's own questions: the conversation, the daily
/// brief and the routines.
///
/// Two kinds, and the owner's decision was to offer both as first-class
/// choices rather than hide one behind the other. Apple's model costs nothing to
/// download and is ready the moment Apple Intelligence is; a downloaded brain
/// works on any iPhone, with Apple Intelligence on or off, and is the only kind
/// the server can lend to other devices — Apple's model is not ours to serve.
/// So this choice is about the phone alone. Whatever it says, the server keeps
/// using a downloaded brain, and nothing here can change that.
public enum BrainChoice: Sendable, Hashable {
    /// Apple Intelligence, through FoundationModels. iOS 26 and later.
    case builtIn
    /// A GGUF brain on disk, by its `ModelRecord.id`.
    case downloaded(id: String)

    /// The model id the rest of the app files this choice under — the
    /// conversation's analytics, a brief's `source`, the engine's residency.
    public var modelID: String {
        switch self {
        case .builtIn: ModelRecord.builtInID
        case let .downloaded(id): id
        }
    }

    public var isBuiltIn: Bool { self == .builtIn }
}

// MARK: - Persistence

public extension BrainChoice {
    /// Where the choice lives. Its own key rather than `pocketd.loadedModel`,
    /// which keeps meaning "the downloaded brain the engine should hold": the
    /// server needs that answer whichever brain the phone is talking to, and
    /// one key answering two questions is how a user who picked Apple's model
    /// finds the server has stopped serving.
    static let defaultsKey = "pocketd.brainChoice"

    /// A plain string, so the value reads sensibly in a defaults dump and in
    /// the stored-data audit: `builtIn` or `downloaded:<id>`.
    var storedValue: String {
        switch self {
        case .builtIn: "builtIn"
        case let .downloaded(id): "downloaded:\(id)"
        }
    }

    /// `nil` for anything this build did not write, including an empty id.
    /// A choice that cannot be read is no choice, and "no choice" has a
    /// well-defined answer (see `effective`); a guess does not.
    init?(storedValue: String) {
        if storedValue == "builtIn" {
            self = .builtIn
            return
        }
        let prefix = "downloaded:"
        guard storedValue.hasPrefix(prefix) else { return nil }
        let id = String(storedValue.dropFirst(prefix.count))
        guard !id.isEmpty else { return nil }
        self = .downloaded(id: id)
    }

    /// What this phone chose, or what it implicitly chose before the choice
    /// existed.
    ///
    /// Everyone who installed a version before this one picked a downloaded
    /// brain by downloading it, and `pocketd.loadedModel` is the record of
    /// that. Reading it as their choice keeps an upgrade from switching their
    /// brain under them — and does not write it, so nothing is decided on
    /// their behalf until they decide.
    static func load(
        from defaults: UserDefaults = .standard,
        legacyLoadedModelKey: String = "pocketd.loadedModel"
    ) -> BrainChoice? {
        if let raw = defaults.string(forKey: defaultsKey), let stored = BrainChoice(storedValue: raw) {
            return stored
        }
        guard let legacy = defaults.string(forKey: legacyLoadedModelKey), !legacy.isEmpty,
              legacy != ModelRecord.builtInID
        else { return nil }
        return .downloaded(id: legacy)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(storedValue, forKey: Self.defaultsKey)
    }
}

// MARK: - Deciding

public extension BrainChoice {
    /// Which brain the phone should actually use, given what was chosen and
    /// what is true now.
    ///
    /// The choice is kept as the user made it, and this answers a different
    /// question: what can answer *today*. They differ in three cases, all of
    /// them about something disappearing.
    ///
    /// - The built-in brain on a phone that can no longer run it at all — a
    ///   backup restored onto an older iPhone — or cannot run it in the
    ///   phone's language. Apple Intelligence being turned off or still
    ///   downloading is *not* this case: those are fixable by the user, the
    ///   Brain page says how, and quietly swapping in a 2 GB download because a
    ///   switch was off would be a surprise in the wrong direction.
    /// - A downloaded brain that has been removed. The next installed one
    ///   stands in, which is what the app did before this type existed.
    /// - Nothing chosen yet. A phone that can use the built-in brain uses it —
    ///   it needs nothing and reads the day — otherwise the first installed
    ///   download, otherwise nothing, and the caller shows the choice.
    ///
    /// - Parameter installed: Downloaded brain ids, in the order the caller
    ///   prefers them (the app passes its installed list as it shows it).
    static func effective(
        chosen: BrainChoice?,
        builtIn: BuiltInBrainAvailability,
        installed: [String]
    ) -> BrainChoice? {
        let fallback: BrainChoice? = installed.first.map { .downloaded(id: $0) }
        switch chosen {
        case .builtIn:
            return builtIn.canNeverAnswer ? fallback : .builtIn
        case let .downloaded(id):
            if installed.contains(id) { return .downloaded(id: id) }
            if let fallback { return fallback }
            return builtIn == .available ? .builtIn : nil
        case nil:
            if builtIn == .available { return .builtIn }
            return fallback
        }
    }

    /// The brain to put in front of someone choosing, or `nil` when there is
    /// nothing worth recommending.
    ///
    /// The built-in brain whenever it is ready: nothing to download, nothing to
    /// wait for, and it reads the day. Otherwise the download the caller picked
    /// for this phone (`StarterModels.recommended` today) — but only if it can
    /// read the day too. "Recommendations everywhere offer only brains that can
    /// read your day" is a product rule, and it is enforced here as well as in
    /// the catalogue because recommending a brain that answers "what's on
    /// today?" by inventing a day is the failure the rule was written after.
    ///
    /// Still downloading counts as not ready. Apple's model arrives on its own
    /// schedule — Wi-Fi, power, sometimes hours — and an intro that recommends
    /// a wait of unknown length over a four-minute download has picked the
    /// wrong first impression. The built-in option is still offered, marked
    /// "Getting ready", for anyone who would rather wait.
    static func recommended(
        builtIn: BuiltInBrainAvailability,
        download: ModelRecord?
    ) -> BrainChoice? {
        if builtIn == .available { return .builtIn }
        guard let download, download.toolSupport.isYes else { return nil }
        return .downloaded(id: download.id)
    }
}

// MARK: - The built-in brain's availability

/// Whether Apple's on-device model can answer on this phone right now.
///
/// The Kit's own copy of `SystemLanguageModel.Availability`, because the Kit
/// does not link FoundationModels and every screen that has to word this is
/// tested here. The app maps Apple's reasons onto these in one place
/// (`SystemModelEngine.availability`).
public enum BuiltInBrainAvailability: String, Sendable, Equatable, CaseIterable {
    /// Ready to answer.
    case available
    /// The phone can run it and Apple Intelligence is off in Settings.
    case turnedOff
    /// The phone can run it, it is on, and Apple's model is still arriving.
    case gettingReady
    /// Apple's model is there but does not support the phone's language.
    /// `SystemLanguageModel.availability` says `.available` here; only
    /// `supportsLocale()` knows, and a question in that language would fail
    /// with an error rather than an answer.
    case unsupportedLanguage
    /// This iPhone, its iOS version or its region cannot run it at all. Also
    /// what an unknown future reason maps to: when there is nothing true to
    /// say, the option is not shown.
    case notEligible

    /// Whether nothing the user can do in Settings will make it answer, so
    /// the phone should use a downloaded brain instead.
    public var canNeverAnswer: Bool {
        switch self {
        case .notEligible, .unsupportedLanguage: true
        case .available, .turnedOff, .gettingReady: false
        }
    }
}

/// How the built-in brain is presented, in one place, so the Brain page,
/// onboarding and the You row cannot word it three ways.
///
/// Copy follows ideal-ui.md §3.5–§3.7: "Apple Intelligence" is the name for
/// the model, "Built into iPhone" is the name for the choice, and nothing here
/// mentions tokens, context, model names or iOS internals.
public struct BuiltInBrainOffer: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case ready
        case gettingReady
        case turnedOff
        case unsupportedLanguage
    }

    /// Whether the option exists on this phone at all. A phone that can never
    /// run it is not shown a disabled row; it is shown the download alone.
    public var isListed: Bool
    /// Whether choosing it does something now or later. False only where the
    /// row is not listed and the quiet line below stands in for it.
    public var canChoose: Bool
    public var status: Status?
    /// The grey line under "Built into iPhone" on the Brain page card.
    public var detail: String?
    /// The one quiet line the Brain page shows instead of the card when the
    /// phone could run it but Apple Intelligence is off.
    public var footnote: String?
    /// The link under that footnote, which opens Settings.
    public var settingsAction: String?

    public static let title = "Built into iPhone"
    public static let provider = "Apple Intelligence"
    /// Onboarding's option row, beside the download's.
    public static let onboardingDetail = "Ready now, nothing to download"
    public static let readyDetail = "Apple Intelligence · Nothing to download · Ready"
    public static let gettingReadyDetail = "Apple Intelligence · Nothing to download · Getting ready"
    public static let unavailableFootnote = "Built-in AI isn't available on this iPhone."
    public static let languageFootnote = "Built-in AI doesn't speak your iPhone's language yet."
    public static let turnOnAction = "Turn on Apple Intelligence in Settings"

    public static func make(for availability: BuiltInBrainAvailability) -> BuiltInBrainOffer {
        switch availability {
        case .available:
            BuiltInBrainOffer(
                isListed: true, canChoose: true, status: .ready,
                detail: readyDetail, footnote: nil, settingsAction: nil
            )
        case .gettingReady:
            // Choosable: the choice is remembered and starts answering the
            // moment Apple's model lands, with the conversation saying
            // "getting ready" in between.
            BuiltInBrainOffer(
                isListed: true, canChoose: true, status: .gettingReady,
                detail: gettingReadyDetail, footnote: nil, settingsAction: nil
            )
        case .turnedOff:
            BuiltInBrainOffer(
                isListed: false, canChoose: false, status: .turnedOff,
                detail: nil, footnote: unavailableFootnote, settingsAction: turnOnAction
            )
        case .unsupportedLanguage:
            // One short line and no action: changing the iPhone's language to
            // suit an app is not a fix anybody should be offered.
            BuiltInBrainOffer(
                isListed: false, canChoose: false, status: .unsupportedLanguage,
                detail: nil, footnote: languageFootnote, settingsAction: nil
            )
        case .notEligible:
            BuiltInBrainOffer(
                isListed: false, canChoose: false, status: nil,
                detail: nil, footnote: nil, settingsAction: nil
            )
        }
    }

    /// The You › Brain row's grey line when the built-in brain is the one in
    /// use. One short phrase, per §3.5.
    public static func rowStatus(for availability: BuiltInBrainAvailability) -> String {
        switch availability {
        case .available: "Ready"
        case .gettingReady: "Getting ready"
        case .turnedOff: "Turn on Apple Intelligence"
        case .unsupportedLanguage: "Not available in your language"
        case .notEligible: "Not available on this iPhone"
        }
    }
}

// MARK: - The built-in brain as a residency record

public extension ModelRecord {
    /// The id the built-in brain is filed under wherever the app expects a
    /// model id.
    ///
    /// A colon on purpose: downloaded ids are built from letters, digits, `-`
    /// and `.` (`HuggingFaceSearch.identifier`), so this one can never collide
    /// with a file somebody downloads, and nothing that maps ids to files on
    /// disk can mistake it for one.
    static let builtInID = "system:apple-intelligence"

    /// What `SystemModelEngine.loadedModel()` reports, so code written against
    /// `InferenceEngine` — the routine runner reads `loadedModel()` before it
    /// generates — works unchanged with the built-in brain resident.
    ///
    /// Tool support is declared rather than inferred: the engine hands every
    /// request the calendar, reminders and health tools whenever the user has
    /// them on. Nothing about it is downloaded, so every size is zero.
    static let builtIn = ModelRecord(
        id: builtInID,
        displayName: BuiltInBrainOffer.title,
        repoID: "",
        filename: "",
        parameters: "",
        quantization: "",
        sizeBytes: 0,
        contextLength: 4096,
        license: "Apple",
        toolSupport: .yes
    )

    var isBuiltInBrain: Bool { id == Self.builtInID }
}
