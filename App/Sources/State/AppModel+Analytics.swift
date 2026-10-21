import Foundation
import PocketdKit

/// Usage counts and the review prompt.
///
/// The consent switch, the one door every event goes through, and the gate
/// that decides when the app has earned the App Store question.
@MainActor
extension AppModel {

    func setAnalyticsConsent(_ consent: AnalyticsConsent) {
        guard consent != analyticsConsent else { return }
        analyticsConsent = consent
        UserDefaults.standard.set(consent.rawValue, forKey: Keys.analyticsConsent)
        // Refusing has to do more than stop the tap. Anything queued and not
        // yet flushed goes, and the identifier with it.
        // Both directions. Refusing has to discard rather than merely stop,
        // and granting has to undo that — the SDK persists an opt-out across
        // launches, so a switch that only knew how to turn off would turn off
        // once and then show a control that does nothing forever.
        if consent.permitsSending {
            analytics.resume()
        } else {
            analytics.stopAndForget()
        }
    }

    private var reviewState: ReviewMoment.State {
        get {
            guard let data = UserDefaults.standard.data(forKey: Keys.reviewState),
                  let decoded = try? JSONDecoder().decode(ReviewMoment.State.self, from: data)
            else { return ReviewMoment.State() }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: Keys.reviewState)
        }
    }

    /// Stamps the install date once, on the first launch that ever runs this.
    ///
    /// An install that predates this code gets its stamp today rather than
    /// retroactively, so somebody who has had the app for a month is treated as
    /// new. That is the wrong way round and it is the safe way round: the cost
    /// is a delayed prompt, and the alternative — no stamp — is a prompt on
    /// what might be their first day.
    func noteLaunchForReview(now: Date = Date()) {
        var state = reviewState
        guard state.firstLaunch == nil else { return }
        state.firstLaunch = now
        reviewState = state
    }

    /// Counts one answer that a tool actually supplied.
    ///
    /// Called once per generation, not once per card: a question that reads the
    /// calendar and the reminders is one useful answer, not two.
    func noteToolBackedAnswer(now: Date = Date()) {
        var state = reviewState
        state.toolBackedAnswers += 1
        reviewState = state
        guard ReviewMoment.shouldAsk(state, now: now) else { return }
        wantsReviewPrompt = true
    }

    /// Records that the ask happened, whatever the user did with it.
    ///
    /// iOS does not say whether the sheet was shown or silently swallowed for
    /// being over Apple's yearly limit, so this records the attempt. Treating
    /// an unshown prompt as "not asked" would spend the next one immediately.
    func reviewPromptShown(now: Date = Date()) {
        wantsReviewPrompt = false
        var state = reviewState
        state.lastAsked = now
        reviewState = state
    }

    /// Lets a view report an event without reaching into the sink.
    ///
    /// `analytics` stays private to this type so the taxonomy has one door: a
    /// view holding the sink could call `record` with anything, and the whole
    /// guarantee here is that the set of transmittable facts is the enum.
    func record(_ event: AnalyticsEvent) { analytics.record(event) }
}
