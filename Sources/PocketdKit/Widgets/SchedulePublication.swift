import Foundation

/// What the app tells a widget, and deliberately nothing more.
///
/// A widget extension is a separate process with its own container, so it can
/// read nothing of this app's without an App Group. That constraint is usually
/// an annoyance; here it is the feature. Rather than open the schedule store to
/// a second process, the app PUBLISHES this — a small, denormalised snapshot
/// written after anything that could change it — and the widget reads only
/// this. The store stays the source of truth and stays where it is, so there is
/// no migration, and the boundary between "what the app knows" and "what a home
/// screen may show" is a type rather than a habit.
///
/// THE FIELD THIS TYPE DOES NOT HAVE is the point of it. `TaskRun.output` is
/// `Untrusted<String>`, and for good reason: for a watcher task it is
/// `report.text`, which is the headline AND the per-item lines — event titles
/// written by whoever sent the invite, routinely naming other people. For a
/// prompt task it is the model's raw answer about a calendar, a reminder list
/// or a health record. `NotificationCentre` already refused to put that on a
/// lock screen banner, and a widget is the harder case of the same argument: a
/// banner is transient and a home screen is permanent, sits in screenshots, and
/// is read over shoulders by people who were never shown a permission prompt.
///
/// So this carries no run text at all — not the output, not the lines, not even
/// the headline. What it carries is enough to answer "is something waiting for
/// me", which is a widget's actual job; what it found is behind the app, where
/// a person had to unlock a phone to get to it. That is also the recoverable
/// direction. A per-widget "show the headline" switch can be added later,
/// opt-in and informed. Nothing can un-show a home screen.
public struct SchedulePublication: Codable, Sendable, Equatable {

    /// Both targets and both entitlements files must agree on this literal, and
    /// it must be registered on the App ID in the developer portal or automatic
    /// signing fails for a device build. Written out rather than derived from
    /// the bundle identifier for the same reason the background-refresh
    /// identifier is: `make device-install BUNDLE_ID=…` overrides the bundle id
    /// on exactly the build that goes on hardware, and a derived group would
    /// move while the entitlement stayed put.
    public static let appGroup = "group.dev.pocketd.app"
    public static let filename = "schedule-publication.json"

    /// The next thing due, if anything is.
    public struct Upcoming: Codable, Sendable, Equatable {
        /// The user's own words. The one string on a widget that a stranger
        /// reading it learns nothing from that the owner did not choose to put
        /// on their own home screen.
        public var title: String
        /// Published as an instant, not as "in 2 hours". A widget's timeline is
        /// reloaded on the system's schedule, not ours, so a rendered relative
        /// phrase is stale the moment it is written; `Text(_:style:.relative)`
        /// counts down on its own between reloads.
        public var firing: Date
        /// Whether this one needs a model, and therefore cannot run while the
        /// app is closed. The widget says so rather than letting the hour
        /// arrive and nothing appear.
        public var needsModel: Bool

        public init(title: String, firing: Date, needsModel: Bool) {
            self.title = title
            self.firing = firing
            self.needsModel = needsModel
        }
    }

    /// How the last run ended — the state, never the text.
    public enum Standing: String, Codable, Sendable, Equatable {
        case reported
        case nothingToReport
        case waiting
        case trouble
    }

    public struct Latest: Codable, Sendable, Equatable {
        public var title: String
        public var ranAt: Date
        public var standing: Standing

        public init(title: String, ranAt: Date, standing: Standing) {
            self.title = title
            self.ranAt = ranAt
            self.standing = standing
        }
    }

    public var generatedAt: Date
    public var next: Upcoming?
    public var latest: Latest?
    /// Enabled tasks, so an empty widget can tell "none set up" from "none due".
    public var enabledCount: Int
    /// Runs that came due where they could not think and are owed.
    public var waitingCount: Int

    public init(
        generatedAt: Date,
        next: Upcoming? = nil,
        latest: Latest? = nil,
        enabledCount: Int = 0,
        waitingCount: Int = 0
    ) {
        self.generatedAt = generatedAt
        self.next = next
        self.latest = latest
        self.enabledCount = enabledCount
        self.waitingCount = waitingCount
    }

    /// Nothing set up yet, which is a different widget from "nothing due".
    public static func empty(at instant: Date) -> Self {
        SchedulePublication(generatedAt: instant)
    }
}

// `Standing(_ outcome:)` lives in SchedulePublication+Make.swift, not here, and
// the split is load-bearing rather than tidy. THIS file and its store are
// compiled into the widget extension directly instead of linking PocketdKit,
// because the kit depends on FlyingFox — an HTTP server, in a process with a
// ~30 MB ceiling that only ever reads one small JSON file. Keeping this file
// free of every PocketdKit type is what makes that possible, and one reference
// to `TaskRun` would end it. Nothing the widget does needs that initialiser:
// only the app publishes; the widget reads.
