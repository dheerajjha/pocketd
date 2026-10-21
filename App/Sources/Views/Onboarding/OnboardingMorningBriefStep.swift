import PocketdKit
import SwiftUI

/// Screen four: the brief, every morning, at a time somebody chose.
///
/// The routine this sets up is a *brief* routine: at the chosen time a
/// notification says "Your morning brief is ready." with one sentence about the
/// day, and tapping it opens Today, where the brief is. It needs no brain, so
/// it works from the first morning whatever is still downloading.
///
/// Three things the old screen got wrong, and how this one avoids them:
///
/// - **The time was a wheel.** A vertical swipe meant for the page landed on
///   it and silently moved 7:30 to 7:43. This is a compact time row: one tap
///   opens the picker, and nothing a scroll does can change it.
/// - **The primer was under the button.** "Next, tap Allow." sat at the end
///   of the scroll and the pinned button covered it. It is now in the footer,
///   directly above the button — and only while iOS has never been asked, so a
///   replay does not promise a sheet that will not appear.
/// - **A replay added a second Morning brief.** `setUpMorningBrief` moves the
///   one that is there, and the row starts at its time.
///
/// The example notification is written from the reader's own day when
/// anything is connected — the same sentence the real banner will carry,
/// built by `BriefPrompt.notificationSentence` from Today's own reading — and
/// otherwise says what a brief holds without inventing a figure.
struct OnboardingMorningBriefStep: View {
    @Environment(AppModel.self) private var model

    /// Held by the flow — see `OnboardingFlow.briefTime`. A time somebody set
    /// and then lost by tapping Back is a time they have to set twice.
    @Binding var time: TimeOfDay
    @Binding var weekdaysOnly: Bool
    /// Whether iOS has never been asked about notifications, so Set it up
    /// will raise its sheet. Read by the flow when the intro opens, so it is
    /// known by the time this screen appears; `nil` until then.
    ///
    /// The primer shows unless iOS is *known* to have answered. Waiting for
    /// the answer instead left a first run with no primer at all on the
    /// simulator, where the settings read queued for two minutes behind a
    /// Health request that could not present — and on a first run the sheet
    /// is coming. A replay, where iOS has answered, shows none.
    var notificationsUndecided: Bool?

    var onContinue: () -> Void

    @State private var saving = false

    /// `TimeOfDay` on the way in and out, `Date` in the middle, because
    /// `DatePicker` has no hour-and-minute type. Only the two components are
    /// ever read back.
    private var picked: Binding<Date> {
        Binding(
            get: { RoutineDraft.date(from: time) },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                time = TimeOfDay(hour: parts.hour ?? 7, minute: parts.minute ?? 30)
            }
        )
    }

    var body: some View {
        OnboardingPage(
            ornament: .icon("sun.horizon"),
            headline: Intro.Copy.morningTitle,
            secondary: Intro.Copy.morningLine,
            primer: notificationsUndecided != false ? Intro.Copy.morningPrimer : nil,
            primary: .init(Intro.Copy.setItUp, isLoading: saving, run: setUp),
            escape: .init(Intro.Copy.notNow, run: onContinue)
        ) {
            VStack(alignment: .leading, spacing: PDSpacing.l) {
                PDCard(warm: true) {
                    // One row while the time and the switch fit side by side —
                    // they do at the default text size on every current iPhone
                    // — and two once they do not. The single row is what keeps
                    // the example notification fully on screen above the pinned
                    // button without a scroll; as two rows the card pushed it
                    // under the button on an iPhone 17 Pro.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: PDSpacing.s) {
                            timePicker
                                .labelsHidden()
                            Spacer(minLength: PDSpacing.s)
                            weekdaysToggle
                                .fixedSize()
                        }
                        VStack(alignment: .leading, spacing: PDSpacing.s) {
                            timePicker
                            Divider().overlay(Color.pd.cardStrokeWarm)
                            weekdaysToggle
                        }
                    }
                }

                VStack(alignment: .leading, spacing: PDSpacing.s) {
                    SectionLabel(Intro.Copy.exampleLabel, tint: .pd.inkSecondaryWarm)
                    ExampleNotification(
                        time: Format.time(RoutineDraft.date(from: time)),
                        title: headline,
                        message: exampleSentence
                    )
                }
            }
        }
    }

    // MARK: - The two controls

    /// A compact time: one tap opens the picker, and nothing a scroll of the
    /// page does can move it. Labelled "Time" for VoiceOver in either layout.
    private var timePicker: some View {
        DatePicker(selection: picked, displayedComponents: .hourAndMinute) {
            Text("Time")
                .font(Font.pd.rowTitle)
                .foregroundStyle(Color.pd.ink)
        }
        .datePickerStyle(.compact)
        .tint(Color.pd.accentWarm)
        .frame(minHeight: PDMetric.minHitTarget)
    }

    private var weekdaysToggle: some View {
        Toggle(isOn: $weekdaysOnly) {
            Text("Weekdays only")
                .font(Font.pd.rowTitle)
                .foregroundStyle(Color.pd.ink)
        }
        .tint(Color.pd.accentWarm)
        .frame(minHeight: PDMetric.minHitTarget)
    }

    // MARK: - The example

    /// What the real banner's title will say — the routine's own words.
    private var headline: String {
        BriefRoutine.headline(for: RoutineTemplate.morningBrief.task(time: time, weekdaysOnly: weekdaysOnly))
    }

    /// The banner's second line, from Today's reading of the day.
    private var exampleSentence: String {
        BriefPrompt.notificationSentence(snapshot: model.briefing.snapshot, now: DemoClock.now)
            ?? Intro.Copy.exampleFallback
    }

    // MARK: - Setting it up

    /// Asks iOS for notifications if it has never been asked — at the tap,
    /// which is the one moment the question is obviously about what somebody
    /// just did — then creates the brief routine, or moves the one already
    /// here. Moves on only once iOS has its answer, so the sheet appears over
    /// the screen that primed it.
    private func setUp() {
        guard !saving else { return }
        saving = true
        Task {
            await model.setUpIntroMorningBrief(at: time, weekdaysOnly: weekdaysOnly)
            saving = false
            Haptics.success()
            onContinue()
        }
    }
}

// MARK: - The example notification

/// A lock-screen banner, drawn: the Pocketd mark, the app name, the time, the
/// title and one sentence.
///
/// Drawn rather than described because "a notification at 7:30" is abstract
/// and a banner with somebody's own next meeting in it is not. Read by
/// VoiceOver as one element that says it is an example.
private struct ExampleNotification: View {
    let time: String
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: PDSpacing.xxs) {
            HStack(spacing: PDSpacing.xs) {
                PocketdMark()
                    .frame(width: 20, height: 20)
                Text("Pocketd")
                    .font(Font.pd.footnote.weight(.semibold))
                    .foregroundStyle(Color.pd.inkSecondaryWarm)
                Spacer(minLength: PDSpacing.xs)
                Text(time)
                    .font(Font.pd.footnote)
                    .foregroundStyle(Color.pd.inkSecondaryWarm)
            }
            .padding(.bottom, PDSpacing.xxs)

            Text(title)
                .font(Font.pd.rowTitle)
                .foregroundStyle(Color.pd.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .font(Font.pd.secondary)
                .foregroundStyle(Color.pd.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(PDSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pdCardSurface(radius: PDRadius.smallCard, fill: .pd.cardWarm, stroke: .pd.cardStrokeWarm)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example notification at \(time). \(title) \(message)")
    }
}

/// The app icon's mark — an arc between two white dots, a cyan dot at its top,
/// on the night-blue square — small enough to sit in a banner.
///
/// Drawn rather than loaded: an app icon set is not an image a view can name,
/// and this is the one place inside the app that needs the mark.
private struct PocketdMark: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
                    .fill(Color(red: 0.04, green: 0.055, blue: 0.094))
                // A cubic whose peak lands under the cyan dot, as on the icon.
                Path { path in
                    path.move(to: CGPoint(x: side * 0.16, y: side * 0.68))
                    path.addCurve(
                        to: CGPoint(x: side * 0.84, y: side * 0.68),
                        control1: CGPoint(x: side * 0.16, y: side * 0.17),
                        control2: CGPoint(x: side * 0.84, y: side * 0.17)
                    )
                }
                .stroke(Color.white, style: StrokeStyle(lineWidth: side * 0.08, lineCap: .round))
                dot(at: CGPoint(x: 0.16, y: 0.68), radius: 0.065, color: .white, side: side)
                dot(at: CGPoint(x: 0.84, y: 0.68), radius: 0.065, color: .white, side: side)
                dot(at: CGPoint(x: 0.5, y: 0.29), radius: 0.075, color: Color(red: 0, green: 0.9, blue: 1), side: side)
            }
            .frame(width: side, height: side)
        }
        .accessibilityHidden(true)
    }

    private func dot(at point: CGPoint, radius: CGFloat, color: Color, side: CGFloat) -> some View {
        Circle()
            .fill(color)
            .frame(width: radius * 2 * side, height: radius * 2 * side)
            .position(x: point.x * side, y: point.y * side)
    }
}

#Preview("Every morning light") {
    OnboardingMorningBriefPreview()
}

#Preview("Every morning dark") {
    OnboardingMorningBriefPreview().preferredColorScheme(.dark)
}

#Preview("Every morning AX") {
    OnboardingMorningBriefPreview().dynamicTypeSize(.accessibility3)
}

private struct OnboardingMorningBriefPreview: View {
    @State private var time = RoutineTemplate.morningBrief.defaultTime
    @State private var weekdaysOnly = true

    var body: some View {
        OnboardingStepPreview {
            OnboardingMorningBriefStep(time: $time, weekdaysOnly: $weekdaysOnly, onContinue: {})
        }
        .environment(AppModel())
    }
}
