import Foundation

/// Pocketd Pro: the one thing Pocketd sells, who already has it, and what it
/// opens.
///
/// A one-time, non-consumable purchase — no subscription, no account, no ads.
/// What it unlocks is decided here rather than on each screen, so the switch on
/// Use from your laptop, the "+" on Routines and the More brains list cannot
/// drift into three different answers, and so every rule can be tested without
/// StoreKit. `ProStore` in the app is the only thing that talks to the App
/// Store; it brings these functions the facts and draws what they say.
///
/// Free, forever: Today and everything on it, the conversation with either
/// brain (Built into iPhone, and the one recommended download), widgets, Siri
/// and Control Center, the Morning brief and the Overdue nudge, privacy, and
/// every brain already on the phone. Pro is the three `ProFeature`s.
///
/// Nothing here records analytics, and nothing should: purchases are counted
/// by App Store Connect, and an event about them would change the App Privacy
/// label for no information Apple does not already report.
public enum ProAccess {

    /// The App Store product. Non-consumable, and created in App Store Connect
    /// under exactly this identifier.
    public static let productID = "dev.pocketd.app.pro"

    /// The first build number that is *not* an early supporter's.
    ///
    /// Build numbers are the archive's epoch seconds (`CURRENT_PROJECT_VERSION`
    /// in project.yml): 1.0.0 shipped as 1789244768, 1.0.1 as 1789638888, and
    /// the newest 1.1.0 TestFlight build before Pro existed is 1789676232.
    /// Every App Store build from here on is archived after this moment, so a
    /// first install below it was of a Pocketd that gave the laptop server away
    /// — and that person keeps everything, free.
    public static let firstBuildAfterEarlySupporters = 1_789_700_000

    /// Which App Store signed the app transaction.
    ///
    /// StoreKit's `AppStore.Environment`, mirrored so the rule below can be
    /// tested without StoreKit.
    public enum StoreEnvironment: String, Sendable, Equatable, CaseIterable {
        /// The App Store itself: somebody installed Pocketd from it.
        case production
        /// App Review, TestFlight, and a sandbox account.
        case sandbox
        /// A StoreKit configuration file, run from Xcode.
        case xcode
        /// Anything a later StoreKit adds. Never early, like the sandbox.
        case other
    }

    /// `originalAppVersion` read as a build number, or nil when it is not one.
    ///
    /// On iOS that field is the `CFBundleVersion` of the build somebody first
    /// installed, and every App Store build of Pocketd is numbered with ten
    /// digits. Anything else is refused rather than interpreted, because the
    /// one value that matters most is the sandbox's: App Review, TestFlight
    /// and Xcode report "1.0" or "1", a lenient parse reads that as build 1 —
    /// far below the line — and the reviewer becomes an early supporter who is
    /// never shown the purchase they are there to test.
    ///
    /// So: ASCII digits only (no ".", sign, space or separator), no leading
    /// zero, at least nine of them, and few enough to fit an `Int`.
    public static func originalBuild(_ originalAppVersion: String?) -> Int? {
        guard let value = originalAppVersion,
              (9...18).contains(value.utf8.count),
              value.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              value.utf8.first != 0x30
        else { return nil }
        return Int(value)
    }

    /// Whether this install predates Pocketd Pro.
    ///
    /// Both conditions, always. The transaction must come from the real App
    /// Store: the sandbox's version is a placeholder that says nothing about
    /// when anyone installed anything, so a reviewer, a TestFlight tester or a
    /// developer in Xcode is never early, whatever it reads. And the original
    /// build must be a real build number below `firstBuildAfterEarlySupporters`.
    ///
    /// `ProStore` passes nil for both when the app transaction failed
    /// verification or could not be read, so neither of those can grant it.
    public static func isEarlySupporter(environment: StoreEnvironment?, originalAppVersion: String?) -> Bool {
        guard environment == .production, let build = originalBuild(originalAppVersion) else { return false }
        return build < firstBuildAfterEarlySupporters
    }

    /// Whether Pro is on, and why.
    ///
    /// A purchase wins over being early: it is what the person did, and it is
    /// the answer that holds wherever they install Pocketd next.
    public static func entitlement(
        purchased: Bool,
        environment: StoreEnvironment?,
        originalAppVersion: String?
    ) -> ProEntitlement {
        if purchased { return .purchased }
        if isEarlySupporter(environment: environment, originalAppVersion: originalAppVersion) { return .earlySupporter }
        return .locked
    }
}

/// Whether Pocketd Pro is on, and why.
public enum ProEntitlement: String, Sendable, Equatable, CaseIterable {
    /// Not bought, and installed after Pro existed.
    case locked
    /// Bought, or restored on this Apple Account.
    case purchased
    /// Installed before Pro existed, when the laptop server was free.
    case earlySupporter

    public var isPro: Bool { self != .locked }
}

// MARK: - What Pro opens

/// The three things Pocketd Pro unlocks, in the order the sheet lists them.
public enum ProFeature: String, CaseIterable, Sendable, Identifiable {
    /// Use from your laptop: the server on this Wi-Fi, desk mode and pairing.
    case laptop
    /// Every routine past the two free ones: the Evening wrap-up, the Weekly
    /// review, and anything made with Custom.
    case routines
    /// Downloading any brain other than the recommended one, and searching
    /// Hugging Face for more. A brain already on the phone stays usable.
    case brains

    public var id: String { rawValue }

    /// The benefit row's title on the Pro sheet.
    public var title: String {
        switch self {
        case .laptop: "Use from your laptop"
        case .routines: "Every routine"
        case .brains: "Any brain"
        }
    }

    /// The benefit row's one grey line.
    public var detail: String {
        switch self {
        case .laptop: "Chat with Pocketd from a browser on your Wi-Fi."
        case .routines: "Evening wrap-ups, weekly reviews and your own."
        case .brains: "Choose from more brains, or search for one."
        }
    }

    /// The same glyphs the features wear elsewhere: the laptop on Use from your
    /// laptop, the alarm on the Routines button, the brain on Brain.
    public var symbolName: String {
        switch self {
        case .laptop: "laptopcomputer"
        case .routines: "alarm"
        case .brains: "brain"
        }
    }
}

// MARK: - Routines

public extension RoutineTemplate {
    /// Whether adding this template needs Pocketd Pro.
    ///
    /// The Morning brief and the Overdue nudge are free: they are what most
    /// people want from routines, and the morning brief is what the intro sets
    /// up. The rest — a second brief in the evening, the weekly review, and the
    /// sleep check when it is offered — are "Every routine".
    var needsPro: Bool {
        switch self {
        case .morningBrief, .overdueWatcher: false
        case .eveningWrapUp, .weeklyReview, .sleepWatcher: true
        }
    }
}

/// What a routine does, in the only terms Pocketd Pro is decided by.
public enum RoutineShape: Sendable, Equatable {
    /// Today's brief, at a time of day.
    case brief
    /// The check for overdue reminders.
    case overdueNudge
    /// Any other check over the calendar or reminders.
    case otherCheck
    /// A question the brain answers.
    case question

    public init(_ body: TaskBody) {
        switch body {
        case .brief: self = .brief
        case .watcher(.reminders(.overdue), _): self = .overdueNudge
        case .watcher: self = .otherCheck
        case .prompt: self = .question
        }
    }

    /// The two shapes the free routines have.
    public var isFree: Bool { self == .brief || self == .overdueNudge }
}

public extension ProAccess {
    /// Whether saving a routine from the editor needs Pocketd Pro.
    ///
    /// - Parameters:
    ///   - body: What the routine will do once saved.
    ///   - original: What it did before this edit; nil for a new routine.
    ///
    /// A new routine from the editor is Custom, which is Pro — even one left
    /// on its default of a brief. An edit that keeps what a routine does is
    /// always free: the time, the days and the name are the person's to
    /// change, and a routine set up before Pro existed stays theirs to tune.
    /// Turning a free routine into something else — the Morning brief into a
    /// question of one's own — is a Custom routine reached the long way round,
    /// and needs Pro like the short way does.
    static func routineNeedsPro(saving body: TaskBody, replacing original: TaskBody?) -> Bool {
        guard let original else { return true }
        let before = RoutineShape(original)
        return before.isFree && RoutineShape(body) != before
    }
}

// MARK: - Brains

public extension ProAccess {
    /// Whether getting this brain needs Pocketd Pro.
    ///
    /// Free when it is Built into iPhone, the one recommended download, or
    /// already on the phone — including a download that is part-way there.
    /// Anything else is "Any brain". Using, choosing or removing a brain that
    /// is on the phone is never gated; this question is only asked of a
    /// download that has not happened yet.
    static func brainNeedsPro(id: String, recommendedID: String?, onPhone: Set<String>) -> Bool {
        if id == ModelRecord.builtInID || onPhone.contains(id) { return false }
        if let recommendedID, id == recommendedID { return false }
        return true
    }
}

// MARK: - Words

/// Everything Pocketd says about Pocketd Pro, in one tested place.
public enum ProCopy {
    public static let name = "Pocketd Pro"
    public static let tagline = "Pay once. Yours for good."
    /// The hero glyph on the sheet.
    public static let symbolName = "sparkles"
    /// The glyph for Pro being on: the You row and the thank-you toast. Not
    /// the sheet's sparkles, which Replay intro already wears in that card.
    public static let statusSymbolName = "checkmark.seal"
    public static let restore = "Restore purchase"
    public static let restoring = "Restoring…"
    public static let notNow = "Not now"
    public static let footer = "One-time purchase. No subscription, no account."
    /// Ask to Buy: the purchase is waiting for a parent.
    public static let waitingForApproval = "Waiting for approval."
    /// The toast once Pro is on — bought, restored, or approved.
    public static let unlocked = "Pocketd Pro is on. Thank you."
    public static let nothingToRestore = "There's no Pocketd Pro purchase on this Apple Account."
    /// The capsule beside a gated control, shown while Pro is off.
    public static let badge = "Pro"
    /// What VoiceOver says for that capsule.
    public static let badgeSpoken = "Needs Pocketd Pro"

    /// The price button: "Unlock for $9.99", the App Store's own price string,
    /// never one written here. "Unlock Pro" while there is no price to show.
    public static func unlockTitle(displayPrice: String?) -> String {
        guard let displayPrice, !displayPrice.isEmpty else { return "Unlock Pro" }
        return "Unlock for \(displayPrice)"
    }

    /// The You row's state.
    public static func rowState(_ entitlement: ProEntitlement) -> String {
        switch entitlement {
        case .locked: "Unlock"
        case .purchased: "On"
        case .earlySupporter: "On — thanks for being early"
        }
    }
}

/// Why a purchase or a restore did not finish, as one plain sentence.
///
/// A person who tapped "Cancel" on Apple's sheet is not a failure and has no
/// case here: they changed their mind, and the sheet says nothing.
public enum ProFailure: String, Sendable, Equatable, CaseIterable {
    /// Screen Time, or a device policy, turns purchases off.
    case notAllowed
    /// The App Store could not be reached.
    case offline
    /// The product did not load, or is not sold in this storefront.
    case unavailable
    /// The App Store's answer did not verify.
    case unverified
    /// Anything else StoreKit reports.
    case other

    public var sentence: String {
        switch self {
        case .notAllowed: "Purchases are turned off in Screen Time on this iPhone."
        case .offline: "Pocketd couldn't reach the App Store. Try again."
        case .unavailable: "Pocketd Pro isn't available right now. Try again later."
        case .unverified: "The App Store couldn't confirm that purchase. Try again."
        case .other: "The purchase didn't go through. Try again."
        }
    }
}
