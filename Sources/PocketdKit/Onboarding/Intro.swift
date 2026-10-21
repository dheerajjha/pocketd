import Foundation

/// The intro's decisions, as plain values the tests can walk through.
///
/// The first run used to be eight screens, and the screens decided things for
/// themselves: the brain screen offered a 386 MB download to a phone that had
/// finished downloading it a minute earlier, the morning-brief screen added a
/// second "Morning brief" on every replay, and the last screen promised "I'll
/// answer the moment the brain is ready" under a card that said it was ready.
/// Each of those was a rule written inside a `body`, where nothing could test
/// it. The rules now live here, and the five screens only draw what these
/// functions say.
public enum Intro {}

// MARK: - The five screens

public extension Intro {

    /// The screens, in the order they are shown.
    enum Screen: Int, Sendable, CaseIterable, Comparable {
        /// "Meet Pocketd." The promises and the usage-counts sentence.
        case meet
        /// "Choose how Pocketd thinks." Built into iPhone or a private download.
        case brain
        /// "Connect your day." Calendar, Reminders and Health on one screen.
        case connect
        /// "Get your day every morning." The morning brief.
        case everyMorning
        /// "You're all set." What is connected, the name, whether Pocketd is ready.
        case allSet

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        /// The funnel's name for this screen.
        ///
        /// `OnboardingStep` still lists the eight screens of the old intro and
        /// is the analytics schema's to change, not this file's. Each new screen
        /// reports the old one it took the place of — the three permission
        /// screens became one, and it reports the first of them — so the funnel
        /// keeps its order and a chart spanning both intros still reads.
        public var analyticsStep: OnboardingStep {
            switch self {
            case .meet: .welcome
            case .brain: .brain
            case .connect: .calendar
            case .everyMorning: .morningBrief
            case .allSet: .ready
            }
        }
    }
}

// MARK: - Choosing how Pocketd thinks

public extension Intro {

    /// What the brain screen offers, which row starts selected, and what
    /// Continue does.
    ///
    /// Both brains are first-class choices (the owner's decision): Apple's,
    /// built into the phone, and a private download that works on any iPhone.
    /// Where the built-in one is ready it is recommended and pre-selected;
    /// where it cannot be offered the screen is the download alone, never a
    /// disabled row.
    ///
    /// The rule this type exists for is the walkthrough's re-download: going
    /// Back to this screen after the download had finished offered "Download
    /// and continue · 386 MB" again, and tapping it fetched the whole file a
    /// second time. A brain that is on the phone is described as on the phone
    /// — whatever was recommended — and Continue never fetches it.
    struct BrainPlan: Sendable, Equatable {

        /// The two rows.
        public enum Option: Sendable, Hashable {
            case builtIn
            case download
        }

        /// The built-in row, when the phone can offer it.
        public enum BuiltIn: Sendable, Equatable {
            /// Apple Intelligence is on and its model is here.
            case ready
            /// Apple Intelligence is on and Apple is still fetching its model.
            /// Choosable: the choice is kept and Pocketd answers once it lands.
            case gettingReady
        }

        /// The download row: which brain, and where it stands.
        public enum Download: Sendable, Equatable {
            /// Not on this phone. Size and time on screen; Continue fetches it.
            case offer(ModelRecord)
            /// On its way now.
            case arriving(ModelRecord)
            /// On this phone already. Never fetched again.
            case onPhone(ModelRecord)

            public var record: ModelRecord {
                switch self {
                case let .offer(record), let .arriving(record), let .onPhone(record): record
                }
            }
        }

        /// How the screen is laid out.
        public enum Layout: Sendable, Equatable {
            /// The built-in row, with the download beside it when one fits.
            case choice
            /// No built-in option on this phone: the one recommended download.
            case downloadOnly
            /// Nothing can be offered. Said once; the intro carries on.
            case nothingFits
        }

        /// What Continue does with the selected row.
        public enum Action: Sendable, Equatable {
            /// The selected brain is the one already set. Move on.
            case nothing
            case useBuiltIn
            /// Choose a download that is here or already arriving.
            case useDownloaded(id: String)
            /// Fetch it, and choose it.
            case download(ModelRecord)
        }

        public var builtIn: BuiltIn?
        public var download: Download?
        /// The brain already set on this phone. Its row says "Ready" (or how
        /// far it has got), and choosing it again does nothing.
        public var inUse: Option?
        /// The "Recommended" mark. Only while nothing is set: on a replay the
        /// brain in use is the answer, and a badge on the other row would read
        /// as advice to switch.
        public var recommended: Option?
        /// The row selected when the screen opens.
        public var preselected: Option?

        public var layout: Layout {
            if builtIn != nil { return .choice }
            if download != nil { return .downloadOnly }
            return .nothingFits
        }

        /// The plan for a phone in this state.
        ///
        /// - Parameters:
        ///   - chosen: The brain the person chose, as `BrainChoice.load()`
        ///     reads it (a v1 install's loaded model counts).
        ///   - builtIn: Whether Apple's model can answer here.
        ///   - installed: Downloaded brains on this phone.
        ///   - arriving: Brains downloading right now.
        ///   - recommendation: `BrainRecommendation.recommended(for:)` — the one
        ///     download Pocketd recommends on this phone, already limited to
        ///     brains that read your day.
        public static func make(
            chosen: BrainChoice?,
            builtIn availability: BuiltInBrainAvailability,
            installed: [ModelRecord],
            arriving: [ModelRecord],
            recommendation: ModelRecord?
        ) -> BrainPlan {
            // The Brain page's rule, not a second copy of it: listed when
            // Apple Intelligence is on, whether or not its model has landed.
            let offer = BuiltInBrainOffer.make(for: availability)
            let builtIn: BuiltIn? = offer.isListed
                ? (offer.status == .ready ? .ready : .gettingReady)
                : nil

            let chosenID: String? = if case let .downloaded(id) = chosen { id } else { nil }
            let pickID = recommendation?.id

            // What is on the phone outranks what could be fetched. A brain that
            // reads the day is the answer, the chosen one first; the
            // recommendation itself counts as here even when it cannot — which
            // only a debug override produces, and which is still not a reason
            // to fetch a file twice. A chat-only brain somebody kept from v1 is
            // not offered: the recommendation is, as the upgrade it is.
            let download: Download?
            if let here = installed.first(where: { $0.id == chosenID && $0.dayAccess().readsYourDay })
                ?? installed.first(where: { $0.dayAccess().readsYourDay })
                ?? installed.first(where: { $0.id == pickID }) {
                download = .onPhone(here)
            } else if let coming = arriving.first(where: { $0.id == chosenID })
                ?? arriving.first(where: { $0.id == pickID })
                ?? arriving.first(where: { $0.dayAccess().readsYourDay }) {
                download = .arriving(coming)
            } else if let recommendation {
                download = .offer(recommendation)
            } else {
                download = nil
            }

            // In use only when it is really there or really coming. A chosen
            // download that stopped half-way is back to an offer, so Continue
            // picks it up again instead of moving on with nothing arriving.
            let inUse: Option?
            switch chosen {
            case .builtIn:
                inUse = builtIn == nil ? nil : .builtIn
            case let .downloaded(id):
                switch download {
                case let .onPhone(record)?, let .arriving(record)?:
                    inUse = record.id == id ? .download : nil
                case .offer?, nil:
                    inUse = nil
                }
            case nil:
                inUse = nil
            }

            let recommended: Option?
            if inUse != nil {
                recommended = nil
            } else {
                switch BrainChoice.recommended(builtIn: availability, download: recommendation) {
                case .builtIn?: recommended = builtIn == nil ? nil : .builtIn
                case .downloaded?: recommended = download == nil ? nil : .download
                case nil: recommended = nil
                }
            }

            let fallback: Option? = download != nil ? .download : (builtIn != nil ? .builtIn : nil)
            return BrainPlan(
                builtIn: builtIn,
                download: download,
                inUse: inUse,
                recommended: recommended,
                preselected: inUse ?? recommended ?? fallback
            )
        }

        /// What Continue does with `selection`.
        public func action(for selection: Option?) -> Action {
            guard let selection, selection != inUse else { return .nothing }
            switch selection {
            case .builtIn:
                return builtIn == nil ? .nothing : .useBuiltIn
            case .download:
                switch download {
                case let .offer(record)?:
                    return .download(record)
                case let .arriving(record)?, let .onPhone(record)?:
                    return .useDownloaded(id: record.id)
                case nil:
                    return .nothing
                }
            }
        }
    }
}

// MARK: - Connecting your day

public extension Intro {

    /// Where one of Calendar, Reminders and Health stands on the connect
    /// screen.
    ///
    /// Read from the switch and from iOS each time the screen draws, never
    /// remembered by the screen: going Back and forward, or replaying the
    /// intro, has to show what is true now rather than what was tapped.
    enum SourceStatus: Sendable, Equatable {
        /// Nothing asked yet, or switched off in Pocketd. The Connect pill.
        case notConnected
        case connected
        /// iOS said no. A trip to the Settings app is the only fix, and the
        /// row's tap takes it.
        case offInSettings
        /// Screen Time or a profile. Nothing on Pocketd's Settings page helps.
        case blocked
        /// This iPhone has no such store.
        case unavailable
        /// The question could not be put. One plain sentence, and Try again.
        case couldNotAsk(reason: String)
        /// Being asked right now — the iOS sheet is up, or about to be.
        ///
        /// Its own state because the door turns the switch on *before* iOS
        /// answers, and Health never reports a grant: read from the switch
        /// alone, the row said "Connected" behind the sheet that was still
        /// asking — and, on a build whose Health sheet never comes, said it
        /// for as long as the screen was open.
        case asking

        /// From the switch and the standing grant.
        ///
        /// Health never reports a read grant, so a Health switch that is on
        /// and was not refused by an error is connected — "On", never "Needs
        /// attention" (ideal-ui §3.5).
        public static func of(_ ability: Ability, isOn: Bool, grant: AbilityGrant) -> SourceStatus {
            if grant == .unavailable { return .unavailable }
            if ability == .health {
                if case let .failed(reason) = grant {
                    return isOn ? .couldNotAsk(reason: reason) : .notConnected
                }
                return isOn ? .connected : .notConnected
            }
            switch grant {
            case .granted: return isOn ? .connected : .notConnected
            case .refused: return .offInSettings
            case .restricted: return .blocked
            // Add-only reads nothing, and a second request can still upgrade
            // it, so it is offered like a source never asked about.
            case .notAsked, .addOnly, .inProgress, .neverReported, .failed: return .notConnected
            case .unavailable: return .unavailable
            }
        }

        public var isConnected: Bool { self == .connected }

        /// The pill's verb, while the row still offers one.
        public var pillTitle: String? {
            switch self {
            case .notConnected: "Connect"
            case .couldNotAsk: "Try again"
            case .connected, .offInSettings, .blocked, .unavailable, .asking: nil
            }
        }

        /// The word on the row's end when there is no pill.
        public var statusWord: String? {
            switch self {
            case .connected: "Connected"
            case .offInSettings: "Off in iOS Settings"
            case .blocked: "Blocked"
            case .unavailable: "Not on this iPhone"
            case .asking: "Asking…"
            case .notConnected, .couldNotAsk: nil
            }
        }

        /// One plain sentence under the row, or nothing.
        ///
        /// Never an iOS error: Health's reasons are already one of
        /// `HealthRequestFailure`'s sentences by the time they get here, so an
        /// unsigned build's entitlement message cannot reach the screen.
        public func note(for ability: Ability) -> String? {
            switch self {
            case let .couldNotAsk(reason): reason
            case .blocked: ConnectOutcome.blocked.sentence(for: ability)
            case .notConnected, .connected, .offInSettings, .unavailable, .asking: nil
            }
        }
    }

    /// The line that names the button the iOS sheet is about to show.
    ///
    /// Word for word what the sheet says, which is the whole job of the line.
    /// The calendar sheet offers "Allow Full Access" beside an add-only choice;
    /// the reminders sheet has a plain "Allow"; Health lists every type with
    /// "Turn On All" above its own "Allow".
    static func primer(for ability: Ability) -> String? {
        switch ability {
        case .calendar: "Next, tap **Allow Full Access**."
        case .reminders: "Next, tap **Allow**."
        case .health: "Next, tap **Turn On All**, then **Allow**."
        case .localServer: nil
        }
    }

    /// The row the primer sits under: the one being connected, or else the
    /// first that still offers Connect.
    ///
    /// One primer at a time. Three "Next, tap…" lines stacked under three rows
    /// say nothing about which comes next; one, under the row about to raise a
    /// sheet, is read before the sheet appears and is still there behind it.
    static func primerRow(connecting: Ability?, statuses: [(Ability, SourceStatus)]) -> Ability? {
        if let connecting { return connecting }
        return statuses.first { $0.1 == .notConnected }?.0
    }
}

// MARK: - The last screen

public extension Intro {

    /// One line of "You're all set": ✓ Calendar, – Health, ✓ Morning brief.
    struct ChecklistItem: Sendable, Equatable, Identifiable {
        public var id: String { title }
        public var title: String
        /// "7:30 AM, weekdays" beside the morning brief. Nothing elsewhere.
        public var detail: String?
        public var isDone: Bool

        public init(title: String, detail: String? = nil, isDone: Bool) {
            self.title = title
            self.detail = detail
            self.isDone = isDone
        }
    }

    /// The tally, in the order the screens asked.
    ///
    /// A dash rather than a cross for anything skipped: it was a choice, and
    /// the Today tile's Off state offers it again in context.
    ///
    /// - Parameter morningBrief: The routine's time as the phone prints it,
    ///   and whether it skips weekends; `nil` when there is none.
    static func checklist(
        calendar: Bool,
        reminders: Bool,
        health: Bool,
        morningBrief: (time: String, weekdaysOnly: Bool)?
    ) -> [ChecklistItem] {
        [
            ChecklistItem(title: "Calendar", isDone: calendar),
            ChecklistItem(title: "Reminders", isDone: reminders),
            ChecklistItem(title: "Health", isDone: health),
            ChecklistItem(
                title: "Morning brief",
                detail: morningBrief.map { "\($0.time), \($0.weekdaysOnly ? "weekdays" : "every day")" },
                isDone: morningBrief != nil
            ),
        ]
    }

    /// Whether Pocketd can answer yet, as the one line the last screen has.
    ///
    /// The old last screen said "Ready" in a card and "I'll answer the moment
    /// the brain is ready" in the sentence under it. One state, one sentence.
    enum Readiness: Sendable, Equatable {
        case ready
        /// Downloading, loading, or Apple still fetching its model. Minutes
        /// once the rate is known.
        case gettingReady(minutes: Int?)
        /// A download that was started has stopped. One action: Try again.
        case stopped
        /// The brain would not start. The reason is `BrainStatus`'s plain one.
        case failed(reason: String)
        /// Nothing chosen and nothing coming — a phone nothing fits.
        case noBrain

        /// From the one status every screen reads.
        ///
        /// - Parameter downloadStopped: A download for the phone's brain is
        ///   paused or failed. `BrainStatus` counts only downloads in flight,
        ///   and a stopped one needs saying here, because nothing else on this
        ///   screen would bring it back.
        public static func of(_ status: BrainStatus, downloadStopped: Bool) -> Readiness {
            switch status {
            case .ready, .cannotReadYourDay:
                return .ready
            // A brain on the phone that is not in memory loads itself when it
            // is needed. Nothing for anybody to wait for or do.
            case .none(hasDownloaded: true):
                return .ready
            case .loading:
                return .gettingReady(minutes: nil)
            case let .arriving(_, minutesLeft):
                return .gettingReady(minutes: minutesLeft)
            case let .failed(reason):
                return downloadStopped ? .stopped : .failed(reason: reason)
            case .none(hasDownloaded: false):
                return downloadStopped ? .stopped : .noBrain
            }
        }

        public var sentence: String {
            switch self {
            case .ready:
                return "Ready."
            case let .gettingReady(minutes?) where minutes > 1:
                return "Pocketd is getting ready — about \(minutes) minutes."
            case .gettingReady(minutes: 1?):
                return "Pocketd is getting ready — about a minute."
            case .gettingReady:
                return "Pocketd is getting ready."
            case .stopped:
                return "The download stopped before Pocketd was ready."
            case let .failed(reason):
                return "The brain didn't start. \(reason)"
            case .noBrain:
                return "Choose how Pocketd thinks any time in You."
            }
        }

        /// The one action the line carries, if any.
        public var actionTitle: String? {
            self == .stopped ? "Try again" : nil
        }
    }
}

// MARK: - The words

public extension Intro {

    /// Every sentence the intro shows that is not built from somebody's data.
    ///
    /// In one place so the tests can hold all of it to the rules in
    /// ideal-ui §1: at most about 25 words a block, the assistant is
    /// "Pocketd" and never "it", verbs on buttons, and no machinery — model
    /// names appear only on the download option, where the size and the time
    /// are the point.
    enum Copy {
        // 1 · Meet Pocketd
        public static let meetTitle = "Meet Pocketd."
        public static let meetLine = "Your day, from your phone, in plain words."
        public static let promises: [(symbol: String, text: String)] = [
            ("person.crop.circle.badge.xmark", "No account"),
            ("lock", "Nothing you ask leaves this phone"),
            ("wifi.slash", "Works with no signal"),
        ]
        public static let usageCounts =
            "Pocketd counts anonymous app usage — never what you ask or read. You can turn it off in You › Privacy."
        public static let getStarted = "Get started"

        // 2 · Choose how Pocketd thinks
        public static let brainTitle = "Choose how Pocketd thinks."
        public static let brainLine = "Pocketd thinks on this iPhone. Nothing you ask leaves it."
        public static let recommended = "Recommended"
        public static let downloadTitle = "Private download"
        public static let downloadWorksAnywhere = "Works even with Apple Intelligence off."
        public static let gettingBrainTitle = "Pocketd is getting its brain."
        public static let gettingBrainLine =
            "Pocketd thinks on this iPhone, so its brain is one download. After that, Pocketd works with no signal."
        public static let hasBrainTitle = "Pocketd has its brain."
        public static let hasBrainLine = "The brain is already on this iPhone, so there is nothing to download."
        public static let onPhoneDetail = "On this iPhone, nothing to download"
        public static let downloadInBackground = "Keeps downloading while you finish setting up."
        /// Said before the meter starts, beside the size it is about.
        public static func mobileData(size: String) -> String {
            "You're on mobile data. This uses about \(size) of your plan; Wi-Fi is quicker."
        }
        public static let nothingFitsTitle = "Choose a brain later."
        public static let nothingFitsLine =
            "None of Pocketd's brains fit this iPhone yet. You can look again any time in You › Brain."
        public static let builtInGettingReady = "Getting ready"
        public static let ready = "Ready"

        // 3 · Connect your day
        public static let connectTitle = "Connect your day."
        public static let connectLine =
            "Pocketd reads these on this iPhone to write your brief and answer you. Each one is optional."

        // 4 · Get your day every morning
        public static let morningTitle = "Get your day every morning."
        public static let morningLine = "Pocketd lets you know when your brief is ready, at the time you choose."
        public static let exampleLabel = "Example notification"
        /// The banner's second line when nothing is connected to write it
        /// from. Says what the brief holds without inventing a figure.
        public static let exampleFallback = "What's next, what's due and how you slept, in one short brief."
        public static let morningPrimer = "Next, tap **Allow**."
        public static let setItUp = "Set it up"
        public static let notNow = "Not now"

        // 5 · You're all set
        public static let allSetTitle = "You're all set."
        public static let allSetLine = "Anything you skipped is one tap away on Today."
        public static let nameQuestion = "What should Pocketd call you?"
        public static let namePlaceholder = "Your first name"
        public static let openPocketd = "Open Pocketd"

        /// The grey line under each source, as You › What Pocketd can see
        /// words it.
        public static func sourceDetail(for ability: Ability) -> String {
            switch ability {
            case .calendar: "Reads and adds events"
            case .reminders: "Reads, adds and ticks off reminders"
            case .health: "Reads sleep and steps"
            case .localServer: ""
            }
        }
    }
}
