import PocketdKit
import SwiftUI
import UIKit

/// Letting a laptop on the same Wi-Fi use this phone's brain.
///
/// v1 called this the Server tab and led with a socket. It is a bonus, not the
/// headline — "your iPhone is the server" is a developer's answer to a
/// developer's question — so it is a section on You, and the words are about
/// what it is for: another device you own, using the brain you already have.
///
/// The section is the same view wherever it appears. The You screen shows it
/// inline; `DevicesView` is the pushed screen with the parts a developer wants
/// under it, and that is the only screen in this app where the jargon is
/// allowed out.
struct OtherDevicesSection: View {
    @Environment(AppModel.self) private var model
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.openURL) private var openURL

    /// Shown on the pushed screen and not on the You root: on the root the
    /// section is a summary, and a request log is the opposite of one.
    var showsRequests = true

    @State private var requestsExpanded = false

    var body: some View {
        YouSection("OTHER DEVICES", footnote: footnote) {
            toggleRow

            if model.serverState.isRunning {
                RowDivider(inset: 0)
                addressBlock
            }

            if let error = model.lastServerError {
                RowDivider(inset: 0)
                Callout(symbol: "exclamationmark.triangle", text: error, tint: .pd.caution, fill: .pd.cautionSoft)
                    .padding(.vertical, PDSpacing.s)
            }

            if !model.condition.isServing {
                RowDivider(inset: 0)
                Callout(
                    symbol: model.condition == .thermal ? "thermometer.high" : "battery.25",
                    text: model.condition.message,
                    tint: .pd.caution,
                    fill: .pd.cautionSoft
                )
                .padding(.vertical, PDSpacing.s)
            }

            if model.serverState.isRunning, model.loadedModelID == nil {
                RowDivider(inset: 0)
                Callout(
                    symbol: "exclamationmark.triangle",
                    text: "Running, but there is no brain loaded — every request will fail until one is.",
                    tint: .pd.caution,
                    fill: .pd.cautionSoft
                )
                .padding(.vertical, PDSpacing.s)
            }

            if showsRequests {
                RowDivider(inset: 0)
                RowDisclosure(
                    title: "Recent requests",
                    detail: model.log.isEmpty ? "Nothing yet" : "\(model.log.count) served this session",
                    symbol: "list.bullet.rectangle",
                    isExpanded: $requestsExpanded
                ) {
                    requestList
                }
            }
        }
    }

    // MARK: - The switch

    private var toggleRow: some View {
        ToggleRow(
            symbol: "laptopcomputer",
            title: "Let my laptop use it",
            detail: toggleDetail,
            isOn: Binding(
                get: { model.serverShouldRun || model.serverState.isRunning },
                set: { on in
                    Haptics.tap()
                    Task { on ? await model.startServer() : await model.stopServer() }
                }
            )
        )
    }

    private var toggleDetail: String {
        switch model.serverState {
        case .starting: "Starting…"
        case .running: "Anything on this Wi-Fi can reach it. Turning this off stops them working until you turn it back on."
        case .failed: "It could not start."
        case .stopped:
            model.loadedModelID == nil
                ? "Choose a brain first — there would be nothing to serve."
                : "Off. Nothing else on your network can reach this phone."
        }
    }

    // MARK: - Address, code, and the two pills

    @ViewBuilder
    private var addressBlock: some View {
        VStack(alignment: .leading, spacing: PDSpacing.m) {
            if let url = model.serverURL {
                VStack(alignment: .leading, spacing: PDSpacing.xxs) {
                    MiniLabel("THE ADDRESS")
                    Button {
                        copy(url.absoluteString, saying: "Address copied")
                    } label: {
                        Text(url.absoluteString)
                            .font(Font.pd.monoValue)
                            .foregroundStyle(Color.pd.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Address \(url.absoluteString). Double tap to copy.")
                }
            }

            pairing

            HStack(spacing: PDSpacing.xs) {
                if let setup = model.setupURL {
                    PillButton(title: "Setup guide", symbol: "arrow.up.right", symbolTrails: true) {
                        openURL(setup)
                    }
                }
                PillButton(title: "Desk mode", symbol: "moon.stars") {
                    model.deskMode = true
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, PDSpacing.s)
    }

    /// The six digits, and the one button the expiry warning names.
    ///
    /// Gated on an open code rather than on whether pairing has ever happened:
    /// asking for a second code has to show it, and a card that only ever
    /// appears once cannot do that.
    @ViewBuilder
    private var pairing: some View {
        if model.pairing.isOpen || !model.pairing.hasPaired {
            VStack(alignment: .leading, spacing: PDSpacing.xxs) {
                MiniLabel("PAIRING CODE")
                HStack(alignment: .firstTextBaseline, spacing: PDSpacing.m) {
                    if let code = model.pairing.code {
                        Text(code)
                            .font(Font.pd.statValue.weight(.semibold))
                            .foregroundStyle(Color.pd.ink)
                            .kerning(5)
                            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                            .accessibilityLabel("Pairing code \(code.map(String.init).joined(separator: " "))")
                    } else {
                        Text("— — — — — —")
                            .font(Font.pd.statValue)
                            .foregroundStyle(Color.pd.inkTertiary)
                            .accessibilityLabel("No pairing code open")
                    }
                    Spacer(minLength: 0)
                    SecondaryLink("New code") {
                        Task { await model.newPairingCode() }
                    }
                }
                expiry
            }
        }
    }

    @ViewBuilder
    private var expiry: some View {
        if let expires = model.pairing.expires, model.pairing.code != nil {
            // SwiftUI's relative style renders a past date as a bare magnitude
            // with no "ago", so an expired code read as "Expires 57 sec" —
            // indistinguishable from time remaining, while the server was
            // already refusing it.
            if expires > .now {
                Text("Expires \(expires, style: .relative)")
                    .font(Font.pd.footnote)
                    .foregroundStyle(Color.pd.inkSecondary)
            } else {
                Text("Expired — tap New code")
                    .font(Font.pd.footnote)
                    .foregroundStyle(Color.pd.caution)
            }
        }
        if model.pairing.failureCount >= PairingSession.maxAttempts,
           let address = model.pairing.lastFailureAddress {
            Text("\(model.pairing.failureCount) wrong codes from \(address). That code is dead — tap New code.")
                .font(Font.pd.footnote)
                .foregroundStyle(Color.pd.caution)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Requests

    @ViewBuilder
    private var requestList: some View {
        if model.log.isEmpty {
            Text("Nothing has asked this phone for anything yet.")
                .font(Font.pd.secondary)
                .foregroundStyle(Color.pd.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, PDSpacing.xs)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(model.log.prefix(12).enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { RowDivider(inset: 0) }
                    requestRow(entry)
                }
                if model.log.count > 12 {
                    Text("and \(model.log.count - 12) more this session")
                        .font(Font.pd.footnote)
                        .foregroundStyle(Color.pd.inkTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, PDSpacing.xs)
                }
            }
        }
    }

    private func requestRow(_ entry: RequestLogEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PDSpacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.clientAddress ?? "this phone")
                    .font(Font.pd.secondary.weight(.medium))
                    .foregroundStyle(Color.pd.ink)
                    .lineLimit(1)
                Text(entry.model ?? entry.path)
                    .font(Font.pd.footnote)
                    .foregroundStyle(Color.pd.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: PDSpacing.xs)
            VStack(alignment: .trailing, spacing: 2) {
                if let rate = entry.tokensPerSecond {
                    Text(String(format: "%.1f tok/s", rate))
                        .font(Font.pd.footnote.monospaced())
                        .foregroundStyle(Color.pd.ink)
                } else {
                    Text("\(entry.statusCode)")
                        .font(Font.pd.footnote.monospaced())
                        .foregroundStyle(entry.statusCode == 200 ? Color.pd.positive : Color.pd.caution)
                }
                Text(entry.date, style: .time)
                    .font(Font.pd.footnote.monospaced())
                    .foregroundStyle(Color.pd.inkTertiary)
            }
        }
        .padding(.vertical, PDSpacing.xs)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Copy

    private var footnote: String {
        model.serverState.isRunning
            ? "iOS closes the connection when this app is in the background, so keep Pocketd on screen while another device is using it. While it is on, the phone announces itself to everything on this Wi-Fi so a laptop can find it without typing the address. Requests that arrive this way can never reach your calendar, reminders or health data."
            : "Turning this on lets another device you own send questions to the brain on this phone, over your own Wi-Fi. Nothing goes to the internet, and a request that arrives this way can never reach your calendar, reminders or health data."
    }

    private func copy(_ value: String, saying message: String) {
        UIPasteboard.general.string = value
        Haptics.success()
        toasts.show(message)
    }
}

// MARK: - The pushed screen

/// Other devices, with the parts a developer came for.
///
/// One of the two screens where the vocabulary is allowed to be technical —
/// this one and Brain → Advanced. Somebody who has pushed into a screen called
/// "Other devices" to find a code snippet is not going to be confused by the
/// word "API".
struct DevicesView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator
    @Environment(ToastCenter.self) private var toasts
    @State private var snippetIndex = 0
    @State private var showKey = false

    var body: some View {
        YouDetailScreen(
            title: "Other devices",
            subtitle: "A laptop or a tablet on this Wi-Fi can send questions to the brain on this phone. It speaks the two APIs those clients already know, so nothing has to be written for it."
        ) {
            OtherDevicesSection()

            if model.pairing.hasPaired {
                connect
            }

            YouSection(
                "ADVANCED",
                footnote: "Which addresses the server answers on, the port, the key, and what a request inherits when it does not say."
            ) {
                NavRow(
                    symbol: "slider.horizontal.3",
                    title: "Server and generation settings",
                    detail: "Port, key, context, sampling"
                ) {
                    navigator.push(.settings)
                }
                if !model.log.isEmpty {
                    RowDivider()
                    NavRow(
                        symbol: "trash",
                        title: "Clear the request log",
                        detail: "\(model.log.count) entries, held in memory only"
                    ) {
                        Task {
                            await model.clearLog()
                            toasts.show("Request log cleared")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Once something has paired

    private var snippets: [ClientSnippet] {
        ClientSnippets.all(
            baseURL: model.serverURL ?? URL(string: "http://127.0.0.1")!,
            apiKey: model.configuration.requiresAuth ? model.configuration.apiKey : nil,
            model: model.loadedModelID ?? "your-model"
        )
    }

    @ViewBuilder
    private var connect: some View {
        let list = snippets
        let snippet = list.indices.contains(snippetIndex) ? list[snippetIndex] : list.first

        YouSection(
            "CONNECTED",
            footnote: snippet?.note ?? "Point any Ollama or OpenAI-compatible client at the address above."
        ) {
            if model.configuration.requiresAuth {
                RowShell(symbol: "key", title: "API key", detail: showKey ? nil : "Hidden until you ask") {
                    Button(showKey ? "Hide" : "Show") { showKey.toggle() }
                        .font(Font.pd.secondary.weight(.semibold))
                        .foregroundStyle(Color.pd.accent)
                        .accessibilityHint("Reveals the key other devices use to reach this phone")
                }
                if showKey {
                    MonoBlock(text: breakableIdentifier(model.configuration.apiKey))
                        .padding(.bottom, PDSpacing.xs)
                }
                NavRow(symbol: "doc.on.doc", title: "Copy the key", detail: nil) {
                    UIPasteboard.general.string = model.configuration.apiKey
                    Haptics.success()
                    toasts.show("Key copied")
                }
                RowDivider()
            }

            if let snippet {
                MenuRow(
                    symbol: "curlybraces",
                    title: "For",
                    detail: nil,
                    selection: $snippetIndex,
                    options: Array(list.enumerated()).map { ($0.offset, $0.element.title) }
                )
                MonoBlock(text: snippet.body, size: 11)
                    .padding(.top, PDSpacing.xs)
                HStack(spacing: PDSpacing.xs) {
                    PillButton(title: "Copy", symbol: "doc.on.doc") {
                        UIPasteboard.general.string = snippet.body
                        Haptics.success()
                        toasts.show("Copied for \(snippet.title)")
                    }
                    ShareLink(item: snippet.body) {
                        HStack(spacing: PDSpacing.xs) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 14, weight: .regular))
                            Text("Share").font(Font.pd.secondary.weight(.semibold))
                        }
                        .foregroundStyle(Color.pd.ink)
                        .padding(.horizontal, PDSpacing.m)
                        .frame(height: PDMetric.pillHeight)
                        .background(Color.pd.chip, in: Capsule(style: .continuous))
                        .overlay(Capsule(style: .continuous).strokeBorder(Color.pd.cardStroke, lineWidth: 1))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, PDSpacing.xs)
            }
        }
    }
}

// MARK: - Previews

#Preview("Devices light") {
    NavigationStack { DevicesView() }
        .environment(AppModel())
        .environment(Navigator())
        .environment(ToastCenter())
}

#Preview("Devices dark") {
    NavigationStack { DevicesView() }
        .environment(AppModel())
        .environment(Navigator())
        .environment(ToastCenter())
        .preferredColorScheme(.dark)
}
