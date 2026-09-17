import SwiftUI
import UIKit

/// You, as a directory.
///
/// v1's Abilities, Models, Server, Settings, Data and Diagnostics screens all
/// live behind this one tab now. This is the placeholder for the profile hub
/// that replaces them: it carries the header and the section structure of the
/// real screen, and every row still reaches the screen it always reached.
///
/// Nothing is lost while the rebuild happens, and nothing here pretends to be
/// finished — the rows say what they go to rather than showing state they do
/// not yet own.
struct YouPlaceholderView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator

    private var brainLine: String {
        model.loadedModelID == nil ? "No brain yet" : model.loadedModelName
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PDSpacing.cardGap) {
                header

                section("What it can see") {
                    // The one row still reached by a destination rather than by
                    // a `YouRoute`: the abilities become rows *on* this screen
                    // when it is rebuilt, so there is no route to name.
                    NavigationLink {
                        AbilitiesView(goTo: { navigator.go($0) })
                    } label: {
                        YouRow(
                            symbol: "sparkles",
                            title: "Calendar, Reminders, Health",
                            detail: "What the assistant is allowed to read"
                        )
                    }
                    .buttonStyle(.plain)
                }

                section("Brain") {
                    route(.brain, symbol: "brain", title: "Brain", detail: brainLine)
                    divider
                    route(.addBrain, symbol: "magnifyingglass", title: "Add a brain", detail: "Search for another one")
                }

                section("Other devices") {
                    route(.devices, symbol: "laptopcomputer", title: "Other devices", detail: "Let a laptop use this phone's brain")
                    divider
                    Button {
                        Haptics.tap()
                        model.deskMode = true
                    } label: {
                        YouRow(symbol: "display", title: "Desk mode", detail: "Full screen, for a phone on a charger")
                    }
                    .buttonStyle(.plain)
                }

                section("Privacy") {
                    route(.privacy, symbol: "lock", title: "What leaves this phone", detail: "Everything this app stores, listed")
                }

                section("Settings") {
                    route(.settings, symbol: "gearshape", title: "Settings", detail: "Server, behaviour, about")
                    divider
                    route(.diagnostics, symbol: "waveform.path.ecg", title: "Diagnostics", detail: "What happened, in order")
                }
            }
            .padding(.horizontal, PDSpacing.gutter)
            .padding(.top, PDSpacing.xs)
        }
        .scrollIndicators(.hidden)
        .pdCanvas()
        .pdHeroWash()
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: PDSpacing.m) {
            Text(model.profile.initial)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(Color.pd.avatar, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(model.profile.greetingName ?? "You")
                    .font(Font.pd.titleDetail)
                    .foregroundStyle(Color.pd.ink)
                Text("Pocketd on \(UIDevice.current.model)")
                    .font(Font.pd.secondary)
                    .foregroundStyle(Color.pd.inkSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, PDSpacing.m)
        .accessibilityElement(children: .combine)
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: PDSpacing.s) {
            SectionLabel(title)
            PDCard(padding: PDSpacing.m) {
                VStack(spacing: PDSpacing.s) {
                    content()
                }
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.pd.divider)
            .frame(height: 1)
    }

    private func route(
        _ route: YouRoute,
        symbol: String,
        title: String,
        detail: String
    ) -> some View {
        NavigationLink(value: route) {
            YouRow(symbol: symbol, title: title, detail: detail)
        }
        .buttonStyle(.plain)
    }
}

/// One row: a small icon tile, two lines, a chevron.
private struct YouRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: PDSpacing.s) {
            IconTile.small(symbol)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Font.pd.rowTitle)
                    .foregroundStyle(Color.pd.ink)
                Text(detail)
                    .font(Font.pd.secondary)
                    .foregroundStyle(Color.pd.inkSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: PDSpacing.xs)
            Image(systemName: "chevron.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.pd.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }
}

/// What each `YouRoute` shows.
///
/// A switch in one place so that adding a route is a compiler error here rather
/// than a blank screen at runtime. The screens themselves are v1's, untouched:
/// each one still brings its own `NavigationStack`, so the pushed screen wears
/// two bars until its own workstream removes the inner one. That is ugly and it
/// is temporary, and it is much better than losing the screens for a week.
struct YouRouteView: View {
    @Environment(AppModel.self) private var model
    let route: YouRoute

    var body: some View {
        switch route {
        case .brain:
            ModelsView()
                .navigationBarTitleDisplayMode(.inline)
        case .addBrain:
            ModelSearchView()
                .navigationBarTitleDisplayMode(.inline)
        case .devices:
            ServerView()
                .navigationBarTitleDisplayMode(.inline)
        case .deskMode:
            // Desk mode is a mode rather than a screen — `RootView` swaps the
            // whole shell for it. Reaching it as a route is possible from
            // `openYou(.deskMode)`, so it gets an honest destination rather
            // than a blank one.
            VStack(spacing: PDSpacing.l) {
                IconTile(symbol: "display")
                Text("Desk mode fills the screen and keeps the brain warm while the phone is on a charger.")
                    .pdSubtitle()
                    .multilineTextAlignment(.center)
                PrimaryButton(title: "Turn on desk mode", arrow: false) {
                    model.deskMode = true
                }
            }
            .padding(PDSpacing.heroGutter)
            .frame(maxHeight: .infinity, alignment: .center)
            .pdCanvas()
            .navigationTitle("Desk mode")
            .navigationBarTitleDisplayMode(.inline)
        case .privacy:
            DataInspectorView()
                .navigationBarTitleDisplayMode(.inline)
        case .settings:
            SettingsView()
                .navigationBarTitleDisplayMode(.inline)
        case .diagnostics:
            DiagnosticsView()
                .navigationTitle("Diagnostics")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview("You placeholder light") {
    NavigationStack {
        YouPlaceholderView()
    }
    .environment(AppModel())
    .environment(Navigator())
}

#Preview("You placeholder dark") {
    NavigationStack {
        YouPlaceholderView()
    }
    .environment(AppModel())
    .environment(Navigator())
    .preferredColorScheme(.dark)
}
