import PocketdKit
import SwiftUI

/// Screen three: Calendar, Reminders and Health, on one screen.
///
/// They used to be three screens, each with a Connect card, a Continue and a
/// Skip, and the third opened with "Let it read your body." Now they are three
/// rows with a Connect pill each, and connecting is optional: Continue is
/// always enabled, and anything skipped is offered again by the Today tile's
/// Off state, in context, rather than by a nag.
///
/// Each pill goes through the one connect door, `connect(_:from:)`, which
/// raises the iOS sheet only where iOS has never answered and opens Settings
/// where it said no. One primer at a time sits under the row that is being —
/// or is next to be — connected, naming the button the sheet is about to show,
/// so it is read before the sheet appears and is still there behind it.
///
/// Every row is read from the phone each time the screen draws
/// (`introSourceStatus`), never remembered here: Back and a replayed intro
/// show what is true now.
struct OnboardingConnectStep: View {
    @Environment(AppModel.self) private var model

    var onContinue: () -> Void

    /// The row whose iOS sheet is up, if any. A second tap on it while the
    /// sheet is up shares the first trip's answer (the door's own rule), so
    /// this only decides where the primer sits.
    @State private var connecting: Ability?

    private static let sources: [Ability] = [.calendar, .reminders, .health]

    var body: some View {
        // The row being asked about says so, whatever the switch says: the
        // door turns it on before iOS has answered.
        let statuses = Self.sources.map { ability in
            (ability, connecting == ability ? Intro.SourceStatus.asking : model.introSourceStatus(ability))
        }
        let primerRow = Intro.primerRow(connecting: connecting, statuses: statuses)

        OnboardingPage(
            ornament: .icon("calendar"),
            headline: Intro.Copy.connectTitle,
            secondary: Intro.Copy.connectLine,
            primary: .init("Continue", run: onContinue)
        ) {
            PDCard(warm: true) {
                VStack(alignment: .leading, spacing: PDSpacing.m) {
                    ForEach(statuses, id: \.0) { ability, status in
                        if ability != Self.sources.first {
                            Divider().overlay(Color.pd.cardStrokeWarm)
                        }
                        row(ability, status: status, showsPrimer: primerRow == ability)
                    }
                }
            }
        }
        .onAppear {
            // Fills `personalDataAuthorization`, which the rows read. A cold
            // launch into the intro has not had a scene change to do it yet.
            model.refreshPersonalDataAuthorization()
        }
        .onChange(of: statuses.map { $0.1.isConnected }) { was, now in
            guard zip(was, now).contains(where: { !$0 && $1 }) else { return }
            Haptics.success()
        }
        .animation(PDMotion.gentle, value: primerRow)
    }

    // MARK: - One row

    @ViewBuilder
    private func row(_ ability: Ability, status: Intro.SourceStatus, showsPrimer: Bool) -> some View {
        VStack(alignment: .leading, spacing: PDSpacing.xs) {
            SourceRow(
                symbol: symbol(for: ability),
                title: ability.title,
                detail: Intro.Copy.sourceDetail(for: ability),
                accessory: accessory(ability, status: status),
                action: status == .offInSettings ? { connect(ability) } : nil,
                warm: true
            )

            // Under the text column, not under the icon tile, so the line
            // reads as part of its row.
            Group {
                if let note = status.note(for: ability) {
                    Text(note)
                        .font(Font.pd.footnote)
                        .foregroundStyle(Color.pd.inkSecondaryWarm)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if showsPrimer, let primer = Intro.primer(for: ability) {
                    // Fades in, leaves at once: a primer fading out where the
                    // row's note is fading in drew the two sentences on top
                    // of each other for a moment.
                    Primer(primer, warm: true)
                        .transition(.asymmetric(insertion: .opacity, removal: .identity))
                }
            }
            .padding(.leading, PDMetric.iconTileSmall + PDSpacing.s)
        }
    }

    private func accessory(_ ability: Ability, status: Intro.SourceStatus) -> SourceRow.Accessory {
        if let pill = status.pillTitle {
            return .connect(title: pill) { connect(ability) }
        }
        return .status(status.statusWord ?? "", isOn: status.isConnected)
    }

    // MARK: - Doing it

    /// Through the one door. It sets the switch, asks iOS where iOS has never
    /// answered, opens Settings where it said no, and reads the day again so
    /// Today's tiles are filled by the time the intro ends.
    private func connect(_ ability: Ability) {
        connecting = ability
        Task {
            await model.connect(ability, from: .onboarding)
            if connecting == ability { connecting = nil }
        }
    }

    private func symbol(for ability: Ability) -> String {
        switch ability {
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .health: "heart"
        case .localServer: "antenna.radiowaves.left.and.right"
        }
    }
}

#Preview("Connect light") {
    OnboardingStepPreview {
        OnboardingConnectStep(onContinue: {})
    }
    .environment(AppModel())
}

#Preview("Connect dark") {
    OnboardingStepPreview {
        OnboardingConnectStep(onContinue: {})
    }
    .environment(AppModel())
    .preferredColorScheme(.dark)
}

#Preview("Connect AX") {
    OnboardingStepPreview {
        OnboardingConnectStep(onContinue: {})
    }
    .environment(AppModel())
    .dynamicTypeSize(.accessibility3)
}
