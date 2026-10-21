import PocketdKit
import SwiftUI
import UIKit

/// Use from your laptop: this iPhone answering a browser on another device,
/// over the same Wi-Fi.
///
/// One status card holds what a person looks at, in the order they look at it
/// with the laptop open beside them: the switch, the address to type there,
/// and the code that page will ask for. Everything else — who asked for what,
/// ports and keys — is one row further down.
///
/// There is no "Setup guide" any more. It opened the setup page in Safari *on
/// the phone*: the wrong device for the task, and it left Pocketd, whose
/// listener iOS closes the moment the app is in the background. The address is
/// the guide now; the page the laptop opens asks for the code itself.
///
/// The client snippets, key reveal and the rest of the old pushed screen are
/// gone with it. That screen could not be reached in a release build, and it
/// was the only place this app printed another vendor's name. A laptop gets
/// the snippets from the page it pairs on (`POST /pair`), which is where they
/// are any use.
struct OtherDevicesView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator
    @Environment(ToastCenter.self) private var toasts
    @Environment(ProStore.self) private var pro: ProStore?

    /// The promo is for the first visit only, and "first" has to survive a
    /// relaunch: someone who said Not now has heard the pitch.
    @AppStorage("pocketd.laptopPromoSeen") private var promoSeen = false
    @State private var showsPromo = false
    @State private var showsRequests = false

    /// What the person asked for, rather than what the socket is doing: iOS
    /// closes the listener whenever Pocketd is in the background, and a switch
    /// that flicked off and on again with every trip to the home screen would
    /// be describing iOS, not the choice.
    private var isOn: Bool { model.serverShouldRun || model.serverState.isRunning }

    var body: some View {
        YouDetailScreen(
            title: "Use from your laptop",
            subtitle: "Ask Pocketd from a browser on your laptop. This iPhone does the answering, over your Wi-Fi."
        ) {
            statusCard
            if needsDownloadedBrain {
                brainCard
            }
            if isOn {
                deskModeCard
            }
            moreCard
        }
        .sheet(isPresented: $showsPromo, onDismiss: { promoSeen = true }) {
            promo
        }
        .navigationDestination(isPresented: $showsRequests) {
            RecentRequestsView()
        }
        .task {
            // Only to someone who has not turned it on: the sheet's whole
            // job is to say what turning it on is for. And only with Pocketd
            // Pro — a "Turn on" that opens a price is a bait; without Pro the
            // switch's "Pro" capsule and the Pro sheet say what this is for.
            await pro?.settle()
            if !promoSeen, !isOn, pro?.isPro ?? true { showsPromo = true }
        }
    }

    // MARK: - The first visit

    private var promo: some View {
        PromoSheet(
            symbol: "laptopcomputer",
            title: "Use Pocketd from your laptop.",
            benefits: [
                .init("bubble.left.and.bubble.right", "Private chat in your browser"),
                .init("square.grid.2x2", "Works with apps you already have"),
                .init("wifi", "Stays on your Wi-Fi"),
            ],
            primaryTitle: "Turn on",
            // iOS asks once, the first time the phone shows itself on the
            // network; on later visits nothing appears and the line is merely
            // early.
            primer: "Next, tap **Allow** so your laptop can find this iPhone.",
            onPrimary: {
                promoSeen = true
                showsPromo = false
                // Shown only with Pro (see `.task`); checked again so no path
                // here turns the server on without it.
                if pro?.isPro ?? true {
                    Task { await model.startServer() }
                }
            },
            onSecondary: {
                promoSeen = true
                showsPromo = false
            }
        )
    }

    // MARK: - The status card

    private var statusCard: some View {
        PDCard(padding: PDSpacing.m) {
            VStack(alignment: .leading, spacing: 0) {
                // Turning it on is Pocketd Pro; turning it off never is.
                ProToggleRow(
                    feature: .laptop,
                    symbol: "laptopcomputer",
                    title: "Allow other devices",
                    detail: switchDetail,
                    isOn: Binding(
                        get: { isOn },
                        set: { on in
                            Haptics.tap()
                            Task { on ? await model.startServer() : await model.stopServer() }
                        }
                    )
                )

                if let address = model.laptopAddress {
                    RowDivider(inset: 0)
                    addressBlock(address)
                    // With the key off there is nothing to pair: a code on
                    // screen would contradict the line above it.
                    if model.configuration.requiresAuth {
                        RowDivider(inset: 0)
                        PairingBlock()
                    }
                }

                if model.serverState.isRunning, let sentence = model.condition.phoneSentence {
                    RowDivider(inset: 0)
                    problem(sentence, symbol: model.condition == .thermal ? "thermometer.high" : "battery.25")
                }
                if let error = model.lastServerError {
                    RowDivider(inset: 0)
                    problem(error, symbol: "exclamationmark.triangle")
                }
            }
        }
    }

    private var switchDetail: String {
        switch model.serverState {
        case .starting:
            return "Starting…"
        case .running:
            return model.configuration.requiresAuth
                ? "On. A new device needs the code below."
                : "On. Anything on this Wi-Fi can ask, with no code."
        case .failed:
            return "It couldn't start."
        case .stopped:
            return model.serverShouldRun ? "Starting…" : "Off. Nothing else can reach this iPhone."
        }
    }

    /// The address, big enough to read off a phone propped beside a laptop,
    /// and a tap copies it — the laptop may be the same person's Mac, where
    /// Universal Clipboard carries it across.
    private func addressBlock(_ address: String) -> some View {
        VStack(alignment: .leading, spacing: PDSpacing.xs) {
            MiniLabel("Open this address on your laptop")
            Button {
                guard let url = model.serverURL else { return }
                UIPasteboard.general.string = url.absoluteString
                Haptics.success()
                toasts.show("Address copied", symbol: "doc.on.doc")
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: PDSpacing.s) {
                    Text(address)
                        .font(Font.pd.statText.monospacedDigit())
                        .foregroundStyle(Color.pd.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "doc.on.doc")
                        .font(Font.pd.secondary)
                        .foregroundStyle(Color.pd.inkSecondary)
                        .accessibilityHidden(true)
                }
                .pdHitTarget(alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Address, \(address)")
            .accessibilityHint("Copies it")
        }
        .padding(.vertical, PDSpacing.s)
    }

    private func problem(_ sentence: String, symbol: String) -> some View {
        Label {
            Text(sentence)
                .font(Font.pd.secondary)
                .foregroundStyle(Color.pd.caution)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .font(Font.pd.secondary)
                .foregroundStyle(Color.pd.caution)
        }
        .padding(.vertical, PDSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - A brain for other devices

    /// The server answers with a downloaded brain and never with Apple's, so a
    /// phone without one — one that uses the built-in brain, or has none yet —
    /// has nothing to serve. Said before anyone turns the switch on, because
    /// discovering it from a laptop's "no model loaded" error is the bad way.
    private var needsDownloadedBrain: Bool {
        model.installed.isEmpty
    }

    private var recommended: ModelRecord? {
        BrainRecommendation.recommended(for: model.budget)
    }

    private var brainCard: some View {
        PDCard(padding: PDSpacing.m) {
            VStack(alignment: .leading, spacing: PDSpacing.s) {
                Text("Other devices use a downloaded brain.")
                    .font(Font.pd.rowTitle)
                    .foregroundStyle(Color.pd.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let record = recommended {
                    if let transfer = model.transfer(for: record.id), transfer.isActive {
                        VStack(alignment: .leading, spacing: PDSpacing.xs) {
                            Text("Downloading \(record.displayName) · \(Int((transfer.fraction * 100).rounded(.down)))%")
                                .font(Font.pd.secondary)
                                .foregroundStyle(Color.pd.inkSecondary)
                            ProgressView(value: transfer.fraction)
                                .tint(Color.pd.accent)
                                .accessibilityHidden(true)
                        }
                    } else {
                        Text("\(record.displayName) · \(pdDownloadLine(record.totalDownloadBytes))")
                            .font(Font.pd.secondary)
                            .foregroundStyle(Color.pd.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        PillButton(title: "Download", symbol: "arrow.down") {
                            model.download(record)
                        }
                        .accessibilityLabel("Download \(record.displayName)")
                    }
                } else {
                    Text("This iPhone doesn't have room for one.")
                        .font(Font.pd.secondary)
                        .foregroundStyle(Color.pd.inkSecondary)
                }
            }
        }
    }

    // MARK: - Below the card

    private var deskModeCard: some View {
        PDCard(padding: PDSpacing.m) {
            ActionRow(
                symbol: "moon.stars",
                title: "Desk mode",
                detail: "A dim screen for an iPhone left answering on a charger"
            ) {
                model.deskMode = true
            }
        }
    }

    private var moreCard: some View {
        PDCard(padding: PDSpacing.m) {
            VStack(spacing: 0) {
                NavRow(
                    symbol: "list.bullet.rectangle",
                    title: "Recent requests",
                    detail: model.log.isEmpty
                        ? "None yet"
                        : Format.counted(model.log.count, "request") + " since Pocketd opened"
                ) {
                    showsRequests = true
                }
                RowDivider()
                NavRow(
                    symbol: "slider.horizontal.3",
                    title: "Server settings",
                    detail: "Port, key and limits"
                ) {
                    navigator.push(.settings)
                }
            }
        }
    }
}

/// `YouRouteView` still says `DevicesView()`; the page's name is the one above.
typealias DevicesView = OtherDevicesView

// MARK: - The pairing code

/// The six digits, and the button that replaces them — always there while
/// the phone is serving.
///
/// The old card disappeared, button and all, once anything had paired: a code
/// is only needed until someone uses one, the reasoning went. Which left a
/// second laptop, or the first one after its browser forgot the key, with no
/// way in short of turning the whole thing off and on. Now there is always a
/// "New code", and when there is no code on screen the card says why.
///
/// Its own view so the gentle clock below re-renders only this block, and
/// only every fifteen seconds: a countdown ticking every second cost battery
/// on a phone left serving, and made the whole page churn for nothing.
private struct PairingBlock: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { _ in
            // The real clock, not the timeline entry's date: that is the
            // last scheduled tick, up to fifteen seconds behind, and a code
            // opened in between read "works for 11 more minutes" for a
            // ten-minute code. The timeline only decides when to look again.
            let now = Date.now
            let snapshot = model.pairing
            let live = snapshot.isLive(at: now)
            VStack(alignment: .leading, spacing: PDSpacing.xs) {
                MiniLabel("Pairing code")
                let layout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: PDSpacing.xs))
                    : AnyLayout(HStackLayout(alignment: .center, spacing: PDSpacing.s))
                layout {
                    if live, let code = snapshot.code {
                        codeText(code)
                    } else {
                        Text(absentSentence(snapshot, now: now))
                            .font(Font.pd.secondary)
                            .foregroundStyle(snapshot.ending == .tooManyTries ? Color.pd.caution : Color.pd.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                    PillButton(title: "New code", symbol: "arrow.clockwise") {
                        Task { await model.newPairingCode() }
                    }
                    .accessibilityHint("Shows a fresh six-digit code for another device")
                }
                if live, let expires = snapshot.expires {
                    Text(liveSentence(expires: expires, now: now))
                        .font(Font.pd.footnote)
                        .foregroundStyle(Color.pd.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, PDSpacing.s)
        }
    }

    /// "483 920": two groups of three, because six digits read off one screen
    /// and typed into another are read three at a time anyway.
    private func codeText(_ code: String) -> some View {
        let grouped = code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
        return Text(grouped)
            .font(Font.pd.statValue.weight(.semibold))
            .foregroundStyle(Color.pd.ink)
            .accessibilityLabel("Pairing code, \(code.map(String.init).joined(separator: " "))")
    }

    private func liveSentence(expires: Date, now: Date) -> String {
        let minutes = max(1, Int((expires.timeIntervalSince(now) / 60).rounded(.up)))
        return "Type it on your laptop when it asks. It works for \(Format.counted(minutes, "more minute"))."
    }

    /// Why there is no code to show, from what ended the last one.
    private func absentSentence(_ snapshot: PairingSession.Snapshot, now: Date) -> String {
        if snapshot.isOpen {
            // Open but past its time: the actor only notices when someone
            // tries it, so the clock here says it first.
            return "That code ran out of time."
        }
        switch snapshot.ending {
        case .paired: return "Paired. Another device needs a new code."
        case .tooManyTries: return "Too many wrong tries, so that code stopped working."
        case .expired: return "That code ran out of time."
        case nil:
            return snapshot.hasPaired
                ? "Paired devices reconnect by themselves."
                : "Get a code to pair your laptop."
        }
    }
}

// MARK: - Recent requests

/// What other devices asked this iPhone since Pocketd opened.
///
/// The phone's own record of who has been using it, so it says it in the
/// phone's words — "Question · Answered", "Pairing · Wrong code" — rather than
/// as paths and status numbers. Held in memory only and never written down;
/// the point of the app is that requests do not leave the device, and that
/// includes not keeping them.
struct RecentRequestsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ToastCenter.self) private var toasts

    /// Plenty for "who has been asking", short enough to stay a list.
    private static let shown = 50

    var body: some View {
        YouDetailScreen(
            title: "Recent requests",
            subtitle: "What other devices asked this iPhone since Pocketd opened. Kept in memory only."
        ) {
            if model.log.isEmpty {
                PDCard(padding: PDSpacing.m) {
                    Text("Nothing has asked yet.")
                        .font(Font.pd.secondary)
                        .foregroundStyle(Color.pd.inkSecondary)
                        .padding(.vertical, PDSpacing.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                PDCard(padding: PDSpacing.m) {
                    VStack(spacing: 0) {
                        ForEach(Array(model.log.prefix(Self.shown).enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { RowDivider(inset: 0) }
                            DataRow(
                                title: entry.requestKind,
                                subtitle: subtitle(for: entry),
                                value: Format.time(entry.date)
                            )
                            .padding(.vertical, PDSpacing.s)
                            .accessibilityElement(children: .combine)
                        }
                        if model.log.count > Self.shown {
                            Text("and \(Format.counted(model.log.count - Self.shown, "earlier one"))")
                                .font(Font.pd.footnote)
                                .foregroundStyle(Color.pd.inkSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, PDSpacing.s)
                        }
                    }
                }
                PDCard(padding: PDSpacing.m) {
                    ActionRow(symbol: "trash", title: "Clear the list", isDestructive: true) {
                        Task {
                            await model.clearLog()
                            toasts.show("Cleared")
                        }
                    }
                }
            }
        }
    }

    /// "Answered · 192.168.1.9 · Qwen3 1.7B". The brain by its name or not at
    /// all — an id is what the client typed, not what the phone calls it.
    private func subtitle(for entry: RequestLogEntry) -> String {
        let brain = entry.model.flatMap { id in (model.installed + model.catalog).first { $0.id == id }?.displayName }
        return [entry.outcome ?? "Answering…", entry.clientAddress ?? "this iPhone", brain]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

// MARK: - Previews

#Preview("Other devices light") {
    NavigationStack { OtherDevicesView() }
        .environment(AppModel())
        .environment(Navigator())
        .environment(ToastCenter())
}

#Preview("Other devices dark") {
    NavigationStack { OtherDevicesView() }
        .environment(AppModel())
        .environment(Navigator())
        .environment(ToastCenter())
        .preferredColorScheme(.dark)
}
