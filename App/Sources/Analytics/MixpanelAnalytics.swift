import Foundation
import PocketdKit

#if canImport(Mixpanel)
import Mixpanel

/// The sink that actually transmits.
///
/// It is in the app target rather than in PocketdKit, and that is the shape of
/// the whole file. The package depends on an HTTP server and nothing else,
/// which is why its routes, auth, streaming and DTOs build and test on a Linux
/// runner in seconds; an iOS-only SDK in there would cost that and buy nothing,
/// because the only thing the package needs is the `AnalyticsSink` protocol it
/// already declares.
///
/// The price is that nothing below has a test bundle to run in — the app target
/// has none — so everything that can be stated as a checkable fact lives on the
/// far side of the protocol instead, where the package's suite already holds
/// it: the event taxonomy, the property schema, the error-to-reason mapping,
/// and `RecordingAnalytics`. What is left here is configuration, which is why
/// the comments below carry the reasoning for each argument. A bare `false` is
/// not self-explanatory in six months, and every one of them is the difference
/// between this app's promises being true and being approximately true.
struct MixpanelAnalytics: AnalyticsSink {

    /// The project token, compiled into the binary.
    ///
    /// Not a secret, and worth saying so here so that nobody later "fixes" it
    /// into the Keychain and leaves a comment implying the old builds leaked
    /// something. A Mixpanel project token is the client-side address of where
    /// events go; every copy of every app that sends them carries it, and it
    /// permits writing events to this one project — no read, no export, no
    /// account, nothing that can be pulled back out.
    private static let token = "7580d296e590b8efccefcaaf1245b2a0"

    /// Configures the SDK, once per process, whatever constructs this.
    ///
    /// A `static let` because it is the run-once, thread-safe construct the
    /// language already provides, and because the alternative — storing the
    /// `MixpanelInstance` — cannot be written at all under complete
    /// concurrency checking: the SDK's instance is not `Sendable`, and this
    /// sink has to be.
    private static let configured: Void = {
        let instance = Mixpanel.initialize(
            token: Self.token,
            // No automatic events, and both halves of that are deliberate.
            //
            // `$ae_first_open` fires on the first launch after the SDK was
            // added rather than on the first launch of the install, so every
            // existing user updating into this build would arrive as a new
            // one — landing in the same project as `is_first_launch` and
            // disagreeing with it. See `FirstLaunch` for the flag that gets
            // this right.
            //
            // `$ae_session` measures how long the app was in the foreground.
            // The question this product exists to answer is how long the phone
            // *served*, and those two numbers differ by every minute someone
            // leaves it charging with the screen off — which is the case the
            // whole app is for. `serverStopped` carries the real one.
            trackAutomaticEvents: false,
            // Usage counts are part of this app rather than a setting inside
            // it, so there is no stored refusal to start from. `stopAndForget`
            // below is still implemented properly: the protocol requires it,
            // and a sink that accepted that call and quietly did nothing would
            // be precisely the lie this taxonomy was built to make impossible.
            optOutTrackingByDefault: false
        )
        // One argument above is missing on purpose, and it is worth naming
        // because the parameter reads backwards. `useUniqueDistinctId`
        // defaults to false, which yields a random UUID per install; passing
        // true opts *into* the IDFV, an identifier shared with every other app
        // from the same vendor. The private option is already the default, so
        // the safe edit to this call is no edit.

        // The one setting that could not be fixed by leaving a property off an
        // event. Location is derived server-side from the IP the request
        // arrives on, so it is not a super property that `properties(of:)`
        // could strip on the way past: this line is the only place it can be
        // declined at all, and the SDK's default is on.
        instance.useIPAddressForGeoLocation = false
    }()

    init() {
        // Not a formality. `Mixpanel.mainInstance()` is a `fatalError` when
        // nothing has been initialised — not a no-op and not an optional — so
        // every path that reaches `record` has to have come through here
        // first, and constructing the sink is the only way to get one.
        _ = Self.configured
    }

    func record(_ event: AnalyticsEvent) {
        Mixpanel.mainInstance().track(event: event.name, properties: Self.properties(of: event))
    }

    /// Stop, and forget.
    ///
    /// Nothing in this build calls it — there is no opt-out — and it is
    /// implemented anyway, because the gap between "stopped sending" and
    /// "forgot what it had" is where this kind of promise is usually broken.
    /// Closes the tap first, then discards. The order is the whole function.
    ///
    /// It used to be the other way round, on defensive reasoning that sounded
    /// right and was checkable: "if `reset` is guarded on the opt-out flag,
    /// closing the tap first means the identifier is never discarded". So it
    /// was checked, against mixpanel-swift 4.4.0's source rather than its
    /// documentation, and the answer inverts the conclusion.
    ///
    /// `reset()` (MixpanelInstance.swift:881) *begins with* `flush()`. It is
    /// not guarded on opt-out — but `flush()` is (:980, an early return on
    /// `hasOptedOutTracking()`). So calling `reset` first transmits every
    /// queued event at the exact moment someone asked us to stop, which is the
    /// precise opposite of this method's contract; and calling `optOutTracking`
    /// first makes that flush a no-op while leaving the rest of `reset` — the
    /// persisted-data delete and the new random identifier — to run normally.
    ///
    /// `optOutTracking()` has a flush of its own (:1524) but it is inside
    /// `if people.distinctId != nil`, and this app never touches the People
    /// API, so it does not fire.
    func stopAndForget() {
        let instance = Mixpanel.mainInstance()
        instance.optOutTracking()
        instance.reset()
    }

    /// Undoes `stopAndForget`, which the SDK makes durable.
    ///
    /// `optOutTracking()` ends by persisting the flag, so without this the
    /// switch in Settings would turn off once and never turn back on — across
    /// relaunches, with the UI still showing a control that does nothing.
    /// `optInTracking()` clears it and issues a fresh identifier.
    func resume() {
        Mixpanel.mainInstance().optInTracking()
    }

    /// Flattens an event's properties into what the SDK takes.
    ///
    /// Exhaustive over `AnalyticsValue` by construction, which is the reason
    /// that type is a closed enum rather than `Any`: a new kind of
    /// transmittable value becomes a compile error in this function rather
    /// than a surprise in a payload nobody is looking at.
    ///
    /// A pure translation, and it has to stay one. `AnalyticsSchema` is a
    /// hand-written list of every property name any event may carry, and the
    /// package's suite checks the taxonomy against it — a check that says
    /// nothing about anything added below the protocol. The tempting edit, and
    /// the one to refuse, is a super property registered at initialisation:
    /// it would attach itself to every event ever sent, and no test in this
    /// repository would be able to see it.
    private static func properties(of event: AnalyticsEvent) -> Properties {
        event.properties.mapValues { (value: AnalyticsValue) -> MixpanelType in
            switch value {
            case let .string(text): return text
            case let .int(number): return number
            case let .double(number): return number
            case let .bool(flag): return flag
            }
        }
    }
}

#else

// The SDK is not in this build, and the single change that fixes it is in
// project.yml — deliberately not made here, because that file generates the
// shared Xcode project:
//
//     packages:
//       Mixpanel:
//         url: https://github.com/mixpanel/mixpanel-swift.git
//         exactVersion: 4.4.0
//
//     targets:
//       Pocketd:
//         dependencies:
//           - package: Mixpanel
//             product: Mixpanel
//
// Compiled out rather than deleted so that the app target still builds without
// the package, and builds *the same call sites* either way. Wiring is the part
// that rots, and wiring that is compiled in both configurations cannot.
#warning("Mixpanel is not linked: this build sends no analytics. Add the package to project.yml — see the comment in MixpanelAnalytics.swift.")

/// The same sink with the SDK absent.
///
/// An alias rather than a second empty struct. `NoAnalytics` is already a type
/// with no code capable of transmitting, and the package's own suite asserts
/// that; writing a local copy would add an untested one to the target that has
/// no tests, to say the thing that is already said.
///
/// The `#warning` above is the point of this branch. The failure it guards is a
/// release that ships with every event wired, every dashboard built and nothing
/// arriving — which, from the inside, looks exactly like a product nobody uses.
typealias MixpanelAnalytics = NoAnalytics

#endif
