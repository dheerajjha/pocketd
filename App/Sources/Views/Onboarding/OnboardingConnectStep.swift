import PocketdKit
import SwiftUI
import UIKit

/// Screens three, four and five: the three permissions, one to a screen.
///
/// This is the whole point of the rebuild. v1 *named* Calendar, Reminders and
/// Health on its first screen and asked for none of them — the app's entire
/// differentiator shipped switched off, behind three toggles in Settings, and
/// most people never found it. Here each one gets a screen of its own, in the
/// order the product uses them, and the sentence above the button says what the
/// iOS sheet is about to ask before it appears.
///
/// One view for all three rather than three views, because the only differences
/// are six strings and which switch gets flipped, and three copies of a
/// permission screen is three places for the refusal path to be got wrong.
struct OnboardingConnectStep: View {
    /// The three, as this screen needs them. Not `Ability` — that type carries
    /// the server as a fourth case and a state machine this screen does not
    /// use, and mapping four onto three here would be inventing a rule.
    enum Ability {
        case calendar
        case reminders
        case health
    }

    @Environment(AppModel.self) private var model

    var ability: Ability
    var onContinue: () -> Void

    /// True while the iOS sheet is up. Keeps the button from starting a second
    /// request under the first one's dialog.
    @State private var asking = false

    var body: some View {
        OnboardingPage(
            ornament: .icon(symbol),
            headline: headline,
            secondary: secondary,
            // One way on, not two. "Continue" and "Not now" were stacked on
            // each other and both did exactly this, so the pair read as a
            // choice that was never being offered — the decision on this screen
            // is the Connect button on the card, and this is only the way past
            // it.
            primary: .init("Continue", run: onContinue)
        ) {
            if unavailable {
                // A fact about the hardware. No card, because there is no
                // switch behind it and a Connect button that cannot work is
                // worse than a sentence that says so.
                Text("Health is not available on this device.")
                    .font(Font.pd.body)
                    .foregroundStyle(Color.pd.inkSecondaryWarm)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: PDSpacing.s) {
                    ConnectCard(
                        title: title,
                        symbol: symbol,
                        detail: detail,
                        state: state,
                        primer: primer,
                        actionTitle: asking && state == .connect ? "Asking…" : nil
                    ) {
                        // In `.needsAttention` the card's own label is already
                        // "Open Settings", and asking iOS again would do
                        // nothing: a refused permission cannot be re-prompted
                        // by the app that was refused.
                        if state == .needsAttention {
                            openSettings()
                        } else {
                            connect()
                        }
                    }

                    if state == .needsAttention {
                        // Amber, like the pill above it. A blue information
                        // bubble under an amber card is two different opinions
                        // about how much this matters.
                        Callout(
                            symbol: "gear",
                            text: refusalPrimer,
                            tint: .pd.caution,
                            fill: .pd.cautionSoft
                        )
                    }
                }
            }
        }
        .onChange(of: connected) { was, now in
            guard !was, now else { return }
            Haptics.success()
        }
    }

    // MARK: - Doing it

    private func connect() {
        guard !asking else { return }
        asking = true
        switch ability {
        case .calendar, .reminders:
            let entity: PersonalDataEntity = ability == .calendar ? .calendar : .reminders
            Task {
                await model.requestAccess(to: entity)
                asking = false
                // Only on a grant. Turning the tool on after a refusal leaves a
                // switch that is on, a calendar that is never read, and no way
                // to find out why — the exact failure the You tab's status
                // lines exist to end.
                guard model.personalDataAuthorization[entity]?.canRead == true else { return }
                if entity == .calendar {
                    model.calendarToolsEnabled = true
                } else {
                    model.reminderToolsEnabled = true
                }
            }
        case .health:
            // HealthKit has no request this screen can await: the switch is the
            // request. `AppModel` runs `requestAllReadAccess()` off the didSet
            // and reports what it learned through `healthAvailability`.
            model.healthToolsEnabled = true
            asking = false
        }
    }

    /// Opens Pocketd's own page in Settings, which is the only page an app is
    /// allowed to open. The per-entity privacy switch is one level up from
    /// there, which is why the callout names the path in words as well.
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Where it stands

    private var state: ConnectCard.State {
        switch ability {
        case .calendar: Self.state(of: model.personalDataAuthorization[.calendar])
        case .reminders: Self.state(of: model.personalDataAuthorization[.reminders])
        case .health:
            // Health never confirms a read grant — HealthKit deliberately will
            // not say, so that an app cannot infer what a user hid. "Connected"
            // here means the request was put and the store answered, which is
            // the strongest honest claim available.
            //
            // The third case is the one worth having: the switch is on and iOS
            // could not be asked. Without it the Connect button looks like it
            // did nothing, which on a simulator — where the Health sheet never
            // appears — is exactly what it looks like.
            if !model.healthToolsEnabled {
                .connect
            } else if model.healthAvailability == .available {
                .connected
            } else {
                .needsAttention
            }
        }
    }

    private static func state(of authorization: PersonalDataAuthorization?) -> ConnectCard.State {
        switch authorization {
        case .granted: .connected
        // Add-only is a real grant to *write* and no grant at all to read.
        // Calling it connected would promise a brief about a calendar this app
        // cannot open.
        case .denied, .restricted, .writeOnly: .needsAttention
        case .notDetermined, nil: .connect
        }
    }

    private var connected: Bool { state == .connected }

    private var unavailable: Bool {
        ability == .health && !HealthAccess.isAvailable
    }

    // MARK: - The words

    private var symbol: String {
        switch ability {
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .health: "heart"
        }
    }

    private var headline: String {
        switch ability {
        case .calendar: "Let it see your calendar."
        case .reminders: "Let it keep your to-dos."
        case .health: "Let it read your body."
        }
    }

    private var secondary: String {
        switch ability {
        case .calendar:
            "Ask what's on tomorrow, or have it add an event for you."
        case .reminders:
            "Ask what's overdue, or say 'remind me at five' and it will."
        case .health:
            """
            Ask how you slept or how active you've been. Health is read on this \
            phone and nowhere else.
            """
        }
    }

    /// The card's title, and the shortest honest version of each.
    ///
    /// "Apple Health" is what the spec wrote and what the first build shipped.
    /// It is two words too long: `ConnectCard` puts the status pill on the same
    /// line, and "Apple Health" beside "Needs attention" clipped the pill to
    /// "Needs atte…" on a Pro Max — the widest phone there is. The word the
    /// headline and the detail already use is "Health".
    private var title: String {
        switch ability {
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        case .health: "Health"
        }
    }

    private var detail: String {
        switch ability {
        case .calendar: "Events saved on this iPhone."
        case .reminders: "Tasks you've saved in Reminders."
        case .health: "Sleep, steps and heart rate."
        }
    }

    /// The line that raises acceptance more than any other copy change: iOS's
    /// own sheet is where people decline, and it uses words nobody has been
    /// prepared for.
    private var primer: String {
        switch ability {
        // Word for word what the sheet's own button says, which is the whole
        // job of this line. They are not the same two words: the calendar sheet
        // offers "Allow Full Access" beside an add-only choice, and the
        // reminders sheet on this iOS offers a plain "Allow" — so naming the
        // calendar's button on the reminders screen sends somebody looking for
        // a control that is not there.
        case .calendar: "Next, tap Allow Full Access."
        case .reminders: "Next, tap Allow."
        case .health: "Next, choose what it may read, then tap Allow."
        }
    }

    /// Where the switch actually is. iOS gives no deep link to a per-entity
    /// privacy page, so this names the path and the button opens the app's own
    /// page, which is as close as the system allows anyone to get.
    private var refusalPrimer: String {
        switch ability {
        case .calendar: "Allowed in Settings › Privacy › Calendars."
        case .reminders: "Allowed in Settings › Privacy › Reminders."
        // The store's own reason when there is one — "could not ask iOS" and
        // "not available on this device" are different problems and only one of
        // them is fixed by a trip to Settings.
        case .health: model.healthAvailability.explanation ?? "Allowed in Settings › Health › Data Access."
        }
    }
}

#Preview("Calendar light") {
    OnboardingStepPreview {
        OnboardingConnectStep(ability: .calendar, onContinue: {})
    }
    .environment(AppModel())
}

#Preview("Calendar dark") {
    OnboardingStepPreview {
        OnboardingConnectStep(ability: .calendar, onContinue: {})
    }
    .environment(AppModel())
    .preferredColorScheme(.dark)
}

#Preview("Health light") {
    OnboardingStepPreview {
        OnboardingConnectStep(ability: .health, onContinue: {})
    }
    .environment(AppModel())
}
