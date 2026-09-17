import PocketdKit
import SwiftUI

/// Screen seven: the routine that makes this app worth keeping.
///
/// Everything before it was setup. This is the first thing Pocketd will do on
/// its own, and it is the reason the three permissions two screens back were
/// worth granting — a brief that names a meeting, a due item and last night's
/// sleep is a sentence only a phone that can see all three can write.
///
/// Notification permission is asked by `saveScheduledTask`, at the save of the
/// first task and nowhere else, which is the rule `NotificationCentre`
/// documents: this app opens without a single permission prompt, and the moment
/// somebody schedules something is the one moment a notification request is
/// obviously about what they just did. The primer sits above the button so the
/// iOS sheet is not the first anybody hears of it.
struct OnboardingMorningBriefStep: View {
    @Environment(AppModel.self) private var model

    /// Held by the flow — see `OnboardingFlow.briefTime`. A time somebody
    /// dialled in and then lost by tapping Back is a time they have to dial in
    /// twice.
    @Binding var time: TimeOfDay
    @Binding var weekdaysOnly: Bool

    var onContinue: () -> Void

    @State private var saving = false

    /// `TimeOfDay` on the way in and out, `Date` in the middle, because
    /// `DatePicker` has no hour-and-minute type and today's date is the only
    /// carrier it accepts. Only the two components are ever read back.
    private var wheel: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()
                ) ?? Date()
            },
            set: { picked in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: picked)
                time = TimeOfDay(hour: parts.hour ?? 7, minute: parts.minute ?? 30)
            }
        )
    }

    var body: some View {
        OnboardingPage(
            ornament: .icon("sun.horizon"),
            headline: "Start every day briefed.",
            secondary: """
            Each morning Pocketd writes a short brief from your calendar, \
            reminders and sleep. You can have it read aloud.
            """,
            primary: .init("Set it up", isLoading: saving, run: create),
            escape: .init("Not now", run: onContinue)
        ) {
            VStack(alignment: .leading, spacing: PDSpacing.s) {
                PDCard(warm: true) {
                    VStack(alignment: .leading, spacing: PDSpacing.s) {
                        SectionLabel("Every morning at")
                        // At its own height. The first build clipped it to
                        // 120pt to save space and cut the neighbouring rows
                        // through the middle of their digits, which reads as a
                        // rendering fault rather than as a compact control —
                        // and this screen has room to spare either way.
                        DatePicker(
                            "Time",
                            selection: wheel,
                            displayedComponents: .hourAndMinute
                        )
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)

                        Divider().overlay(Color.pd.cardStrokeWarm)

                        Toggle(isOn: $weekdaysOnly) {
                            Text("Weekdays only")
                                .font(Font.pd.rowTitle)
                                .foregroundStyle(Color.pd.ink)
                        }
                        .tint(Color.pd.accentWarm)
                    }
                }

                Callout(symbol: "hand.tap", text: "Next, tap Allow.")
            }
        }
    }

    private func create() {
        guard !saving else { return }
        saving = true
        let task = RoutineTemplate.morningBrief.task(
            now: Date(),
            time: time,
            weekdaysOnly: weekdaysOnly
        )
        Task {
            // Asks for notifications on its way through, because this is the
            // first task on the phone. See the type note above.
            await model.saveScheduledTask(task)
            model.record(.routineCreated(template: .morningBrief))
            saving = false
            Haptics.success()
            onContinue()
        }
    }
}

#Preview("Morning brief light") {
    OnboardingMorningBriefPreview()
}

#Preview("Morning brief dark") {
    OnboardingMorningBriefPreview().preferredColorScheme(.dark)
}

private struct OnboardingMorningBriefPreview: View {
    @State private var time = RoutineTemplate.morningBrief.defaultTime
    @State private var weekdaysOnly = true

    var body: some View {
        OnboardingStepPreview {
            OnboardingMorningBriefStep(
                time: $time,
                weekdaysOnly: $weekdaysOnly,
                onContinue: {}
            )
        }
        .environment(AppModel())
    }
}
