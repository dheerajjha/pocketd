import PocketdKit
import SwiftUI

/// Today, with the brief left out.
///
/// The skeleton of the real screen and not a mock of it: the header, the card
/// and the chips are the ones that ship, wired to the real `Navigator`, so that
/// the workstream building the briefing engine replaces one card's contents
/// rather than a screen. Everything here is deliberately load-free — no
/// calendar read, no model — because the shell has to come up on a phone with
/// nothing installed.
struct TodayPlaceholderView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator

    /// The four openings. Written as the question a person would type, which
    /// is what makes them read as examples rather than as buttons.
    private static let openings = [
        "What's on tomorrow?",
        "Anything overdue?",
        "How did I sleep?",
        "Remind me to…",
    ]

    /// Results waiting to be written, which is the one thing the bell has to
    /// carry: a scheduled brief that came due while the app was closed cannot
    /// run until somebody opens it.
    private var waiting: Int {
        ScheduleSummary.pending(in: model.scheduledTasks).count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PDSpacing.cardGap) {
                // In the scroll view rather than pinned above it. The wash is
                // on the screen and stays put; the header scrolls away, which
                // is what gives the page its whole height back once somebody
                // is reading rather than arriving.
                HeroHeader(date: Date(), wash: false) {
                    CircleIconButton(
                        symbol: "bell",
                        label: "Routines",
                        badge: waiting
                    ) { navigator.go(.routines) }

                    AvatarButton(initial: model.profile.initial) {
                        navigator.go(.you)
                    }
                }
                .padding(.bottom, PDSpacing.m)

                PDCard {
                    VStack(alignment: .leading, spacing: PDSpacing.s) {
                        HStack(spacing: PDSpacing.xs) {
                            SectionLabel("Today's brief")
                            Circle()
                                .fill(model.loadedModelID == nil ? Color.pd.inkTertiary : Color.pd.positive)
                                .frame(width: 6, height: 6)
                        }
                        Text("Your brief will appear here.")
                            .font(Font.pd.lead)
                            .foregroundStyle(Color.pd.ink)
                            .lineSpacing(6)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Each morning Pocketd writes a short paragraph about your day, on this phone.")
                            .pdBody()
                    }
                }
                .padding(.horizontal, PDSpacing.gutter)
                .pdStaggerIn(0)

                VStack(alignment: .leading, spacing: PDSpacing.s) {
                    SectionLabel("Try asking")
                    ChipFlow {
                        ForEach(Self.openings, id: \.self) { opening in
                            SuggestionChip(opening) {
                                navigator.ask(opening, send: false)
                            }
                        }
                    }
                }
                .padding(.horizontal, PDSpacing.gutter)
                .padding(.top, PDSpacing.xs)
                .pdStaggerIn(1)
            }
            .padding(.top, PDSpacing.xs)
        }
        .scrollIndicators(.hidden)
        // The floating bar's space, as safe area on this scroll view rather
        // than as padding: the page keeps scrolling under the capsule, and the
        // last row still comes out from under it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: PDMetric.tabBarClearance)
        }
        // Wash first, canvas second, and the order is the whole effect.
        // `background` puts each new layer *behind* the last, so applying the
        // flat canvas afterwards paints it over the gradient and the top of the
        // page goes plain white.
        .pdHeroWash()
        .pdCanvas()
        .task {
            // Only so the bell's badge is honest on a cold launch. Cheap, and
            // it is the one number on this screen that is not decoration.
            await model.loadScheduledTasks()
        }
    }
}

#Preview("Today placeholder light") {
    TodayPlaceholderView()
        .environment(AppModel())
        .environment(Navigator())
}

#Preview("Today placeholder dark") {
    TodayPlaceholderView()
        .environment(AppModel())
        .environment(Navigator())
        .preferredColorScheme(.dark)
}
