import SwiftUI
import PocketdKit

/// The first four minutes of owning this app.
///
/// Before this there was nothing: a fresh install opened on the Server tab
/// with no model, a switch that could not usefully be turned on, and no
/// statement anywhere of what the thing was for. The two questions a new
/// person actually has — *what is this* and *what do I do now* — both went
/// unanswered.
///
/// The first answer used to be "Your iPhone is the server." That is the
/// developer's answer to a developer's question, and it only lands for someone
/// who already owns a laptop they want to point at this phone. Everyone else
/// was handed, as sentence one, a description of a product they have no use
/// for — while the single thing here that a local-chat app cannot do, an
/// assistant that can read your calendar, your reminders and your health, went
/// unmentioned until Settings, where it sits behind three switches that default
/// off. The differentiator was invisible and the plumbing was the headline.
///
/// So: assistant first, server second. What it is for, what it cannot do, where
/// the words go, and only then that this phone is also a machine your laptop
/// can talk to. The three abilities are *named* on the opening screen and not
/// offered there — being told they exist is the whole fix, and a permission
/// sheet before anyone has seen a single answer is not.
///
/// It still ends where no other local-LLM app can end: with the address of this
/// phone and something to paste into a laptop. PocketPal's intro finishes by
/// handing you a chat, which is right for a companion app. This is a companion
/// app *and* a server, so the last screen offers both doors and lets the reader
/// pick which half they came for.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    /// Where to leave the person standing. The intro's whole job is to end
    /// somewhere useful, so the destination is the last thing it decides.
    var finish: (AppTab) -> Void

    @State private var step = 0
    @State private var chosen: ModelRecord?

    /// Six screens. The count lives in one place because it used to live in
    /// three that could disagree — the dots, their accessibility label, and the
    /// footer's test for which screens bring their own buttons. Inserting the
    /// server screen moved that boundary by one, and a hard-coded `step < 3`
    /// left behind would have put a second prominent button under the download.
    private var lastStep: Int { 5 }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch step {
                    case 0: whatThisIs
                    case 1: honestLimits
                    case 2: privacyAndNetwork
                    case 3: serverReveal
                    case 4: pickAModel
                    default: whereNext
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 8)
                // 24 was enough until the privacy screen, which is still the
                // tallest in the intro: on a 4.7-inch phone its last rows ran
                // into the page dots, leaving text half-drawn behind them.
                // Enough room that the tail scrolls clear of the footer instead
                // of fighting it.
                //
                // What has to stay above the fold on that screen is now the
                // analytics disclosure rather than the toggle that used to
                // stand there — a disclosure someone has to scroll to find is
                // no better than no disclosure.
                //
                // An iPhone SE leaves this ScrollView 493 points once the
                // status bar, header and footer are taken out, and the privacy
                // copy as it stood wanted 526. That is why its two callouts and
                // its lead paragraph are shorter than they read like they want
                // to be: the 33 points came out of the sentences above the
                // disclosure so that none of it came out of the disclosure.
                // Anything added to that screen has to pay the same way.
                .padding(.bottom, 56)
            }
            footer
        }
        .background(Color(.systemBackground))
        .animation(.snappy, value: step)
    }

    // MARK: Chrome

    private var header: some View {
        HStack {
            if step > 0 {
                Button { step -= 1 } label: {
                    Label("Back", systemImage: "chevron.left")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("Back")
            }
            Spacer()
            // Reachable from every screen including the last. Someone who
            // already knows what this is should never have to read it.
            Button("Skip") { leave(to: .models) }
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .frame(minHeight: 44)
    }

    private var footer: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(0...lastStep, id: \.self) { index in
                    Capsule()
                        .fill(index == step ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: index == step ? 18 : 6, height: 6)
                }
            }
            .accessibilityLabel("Step \(step + 1) of \(lastStep + 1)")

            // The last two screens carry their own buttons — a download with a
            // price on it, and the destination cards. A second prominent button
            // under either one is a competing answer to a question the screen
            // has already asked, so this counts back from the end rather than
            // naming a step index that the next inserted screen would silently
            // shift under it.
            if step < lastStep - 1 {
                Button(action: { step += 1 }) {
                    Text(continueTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }

    private var continueTitle: String {
        switch step {
        case 0: "Show me"
        case 1: "Makes sense"
        case 3: "Pick a model"
        default: "Got it"
        }
    }

    // MARK: Screens

    /// Screen one, and the only place the three abilities are named before
    /// somebody has to go looking for them.
    ///
    /// Named, not offered. The switches belong to the screen that can also show
    /// what each one costs and what iOS said back; putting them here would put
    /// three permission sheets in front of a person who has not yet seen this
    /// app answer a single question, which is how you get three refusals and a
    /// feature that then looks broken rather than off.
    ///
    /// The four windows in the Calendar row are exactly the four `CalendarRange`
    /// accepts, and the Health row names metrics `HealthMetric` actually carries.
    /// A friendlier superset here — "any date", "anything in Health" — would be
    /// a promise the tool schema refuses, and the reader would meet the refusal
    /// as the assistant's first answer.
    private var whatThisIs: some View {
        VStack(alignment: .leading, spacing: 16) {
            eyebrow("What this is")
            // "that knows your day" was the punchier draft and it presumes the
            // three switches are already on, which they are not and cannot be
            // from here. "Can see" is the version that is still true when the
            // next line says nothing is on yet.
            title("An assistant that can see your day.")
            body("""
            Ask what is on today, what is overdue, how you slept — or ask it to \
            set a reminder. It answers here, from your own data — no account, no \
            cloud, and what you type never leaves the phone.
            """)
            // Tighter than the screen's own spacing: three rows that are one
            // list, not three points.
            VStack(alignment: .leading, spacing: 10) {
                calloutRow(icon: "calendar", text: "**Calendar** — today, tomorrow, this week or next, and adding events")
                calloutRow(icon: "checklist", text: "**Reminders** — what is due, what is overdue, and setting new ones")
                calloutRow(icon: "heart", text: "**Health** — steps, sleep, heart rate")
            }
            // "read" was accurate while all three tools were `get_`. Calendar
            // and reminders can now be written to as well, so the sentence a
            // person is shown before they grant anything has to say so.
            body("None of it is on yet. You choose which of the three it can use.")
        }
    }

    private var honestLimits: some View {
        VStack(alignment: .leading, spacing: 16) {
            eyebrow("Before you get excited")
            title("A phone is not a datacentre.")
            body("""
            What fits here is small — a few billion parameters, not a few \
            hundred. Expect a capable assistant for short questions, drafting, \
            summarising and simple code. Do not expect ChatGPT.
            """)
            // The single most useful thing this app knows, said before it can
            // disappoint anyone: the fit estimate exists because the failure
            // mode is a multi-gigabyte download that gets killed on load.
            calloutRow(
                icon: "memorychip",
                text: "Every model says whether it fits *this* iPhone before you spend a gigabyte finding out."
            )
            calloutRow(
                icon: "bolt.slash",
                text: "Generating is hard work. Keep the phone charging if other devices are using it."
            )
        }
    }

    /// The promise, the two exceptions to it, and where the switch governing
    /// the second exception lives — in that order.
    ///
    /// Order is deliberate and the analytics line is last on purpose: a claim
    /// about telemetry above the explanation makes people decide before they
    /// have read anything.
    ///
    /// The headline used to be "Nothing leaves this phone," which was already
    /// slightly overstated before analytics existed — model downloads come
    /// from Hugging Face, and they did in 1.0.0 too. The store listing was
    /// corrected when someone read it closely; this screen was not, because
    /// nobody was looking at it. So this is not only absorbing telemetry, it
    /// is repairing a claim that could not survive being checked.
    ///
    /// "Your words never leave this phone" is the strongest sentence that is
    /// literally true, and it is about the thing people actually worry about.
    private var privacyAndNetwork: some View {
        VStack(alignment: .leading, spacing: 12) {
            eyebrow("Where your words go")
            title("Your words never leave this phone.")
            body("""
            What you type, what the model says back, and anything it reads from \
            your Health, Calendar or Reminders all stay on this device. There is \
            no account and no cloud to sync to.
            """)
            body("Two things do use the network:")

            calloutRow(
                icon: "arrow.down.circle",
                text: "Models are downloaded from Hugging Face, when you choose one."
            )
            // "on real phones" is doing the honest work here: it says why we
            // want this, and the reason is true — model loading could not be
            // tested across real hardware before shipping.
            calloutRow(
                icon: "chart.bar",
                text: "Anonymous counts of which screens are opened and whether models load properly on real phones. Never your words, never the model's, never your location."
            )

            // The sentence outlived the build it described. There was genuinely
            // no way to turn these off when this screen was written, and saying
            // so plainly was the honest thing then — but Settings has carried
            // the switch since, and this text went on telling every new install
            // that no setting existed. A false claim in the direction of *fewer*
            // controls still costs trust, and it costs it on the one screen
            // whose entire job is being believed.
            //
            // Still a statement rather than a second switch: the control is one
            // scroll into Settings, and a consent toggle put in front of someone
            // tapping through an intro is answered by the tapping, not by them.
            Text("These are on by default. The switch that turns them off is at the bottom of Settings.")
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    /// The sentence this intro used to open with, demoted to where it earns its
    /// place.
    ///
    /// Nothing about it was wrong — it is still the thing nothing else in this
    /// category does. It was in the wrong position: it describes a job only
    /// somebody with a second machine to point at this one has, so as screen one
    /// it told most readers, in the first six words, that this app was built for
    /// someone else. After three screens of what the assistant is for, the same
    /// sentence reads as a bonus instead of an entry requirement.
    ///
    /// It comes *after* the privacy screen rather than before it because this is
    /// the screen that first mentions other machines, and the reader's next
    /// thought is whether those machines can see the calendar. The answer is on
    /// screen with the question: `RequestOrigin` fails closed to `.network`, and
    /// `mayReachPersonalData` is on-device chat only.
    private var serverReveal: some View {
        VStack(alignment: .leading, spacing: 16) {
            eyebrow("The other half")
            title("Your phone is also a server.")
            body("""
            Models run on this device, so anything else on the same network — \
            your laptop, your terminal, your editor — can talk to them the same \
            way it would talk to a machine in a datacentre.
            """)
            calloutRow(
                icon: "lock.shield",
                text: "Other devices get the model and nothing else. Your calendar, reminders and health can only be read — or changed — in the chat on this phone."
            )
        }
    }

    private var pickAModel: some View {
        VStack(alignment: .leading, spacing: 16) {
            eyebrow("One thing to do")
            title("Pick something to run.")
            let starters = model.starterModels
            if starters.isEmpty, !model.installed.isEmpty {
                // The replay-from-Settings case. Offering a download here would
                // be answering a question nobody asked.
                body("You already have \(model.installed.count == 1 ? "a model" : "\(model.installed.count) models") on this phone, so there is nothing to fetch.")
                Button("Continue") { step += 1 }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            } else if starters.isEmpty {
                body("""
                Nothing in the built-in list fits this device. The Models tab \
                can search Hugging Face for something smaller.
                """)
                Button("Go to Models") { leave(to: .models) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                body("Sized to this iPhone. You can add more later, or search Hugging Face for anything else.")
                VStack(spacing: 10) {
                    ForEach(Array(starters.enumerated()), id: \.element.id) { index, record in
                        starterRow(record, tier: tierName(index, of: starters.count))
                    }
                }
                Button {
                    if let record = chosen ?? model.recommendedStarter {
                        // Fire and forget. The banner above the tabs follows the
                        // download everywhere, so making someone watch a
                        // progress bar here would be asking them to wait for no
                        // reason.
                        model.download(record)
                        step += 1
                    }
                } label: {
                    Text(downloadTitle(default: model.recommendedStarter))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Not now") { step += 1 }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var whereNext: some View {
        VStack(alignment: .leading, spacing: 16) {
            let started = model.transfers.values.sorted { $0.record.displayName < $1.record.displayName }
            let downloading = started.contains { $0.isActive }
            eyebrow(downloading ? "Downloading now" : "You're set up")
            title("Two ways to use it.")

            // The download the last step started, shown rather than described.
            //
            // This screen used to say "there's a progress bar at the top of
            // every screen" — true the moment you leave, and not true here,
            // because the banner lives above the tab bar and the tab bar is
            // not on screen during the intro. So the one place a first
            // download is almost always started was the one place that could
            // not show it, and the sentence pointed at something the reader
            // could not see.
            ForEach(started) { transfer in
                transferCard(transfer)
            }

            // "Like any assistant app, except offline and private" was the old
            // description, and it gives away the thing screen one just spent
            // its whole height establishing: this is *not* like any assistant
            // app, and the last screen is the worst place to say it is.
            destinationCard(
                icon: "bubble.left.and.bubble.right.fill",
                title: "Chat on this phone",
                detail: "Private, offline, and the only place it can see your day.",
                tab: .chat
            )
            destinationCard(
                icon: "network",
                title: "Connect your laptop",
                detail: "Start the server and pocketd gives you a ready-to-paste line for curl, opencode, Continue, Open WebUI and more.",
                tab: .server
            )
        }
    }

    // MARK: Pieces

    /// A download in progress, on the screen that started it.
    @ViewBuilder
    private func transferCard(_ transfer: ModelTransfer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                switch transfer.state {
                case .waiting, .stopping:
                    ProgressView().controlSize(.small)
                case .running:
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                case .finished:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .paused:
                    Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(transfer.record.displayName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(transferLine(transfer))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            switch transfer.state {
            case .waiting:
                ProgressView().progressViewStyle(.linear)
            case .running, .stopping, .paused:
                ProgressView(value: transfer.fraction).progressViewStyle(.linear)
            case .finished, .failed:
                EmptyView()
            }
            if case .failed = transfer.state {
                Button("Try again") { model.download(transfer.record) }
                    .font(.caption)
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }

    private func transferLine(_ transfer: ModelTransfer) -> String {
        switch transfer.state {
        case .waiting:
            return "Starting · \(ByteCountFormatter.string(fromByteCount: transfer.record.totalDownloadBytes, countStyle: .file)) to fetch"
        case .stopping:
            return "Stopping · checking what can be kept"
        case let .running(progress):
            let percent = Int((transfer.fraction * 100).rounded(.down))
            var line = "\(percent)% · \(ByteCountFormatter.string(fromByteCount: progress.receivedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))"
            if let pace = model.pace(for: transfer.id), pace.bytesPerSecond > 0 {
                line += " · \(ByteCountFormatter.string(fromByteCount: Int64(pace.bytesPerSecond), countStyle: .file))/s"
            }
            return line
        case .finished:
            return model.loadingModelID == transfer.id
                ? "Downloaded · loading it now"
                : "Downloaded · ready to use"
        case let .paused(message):
            return message
        case let .failed(message):
            return message
        }
    }

    private func starterRow(_ record: ModelRecord, tier: String) -> some View {
        let isChosen = (chosen ?? model.recommendedStarter)?.id == record.id
        return Button {
            chosen = record
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isChosen ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isChosen ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(record.displayName).font(.headline)
                        Text(tier)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.15), in: Capsule())
                    }
                    Text("\(record.parameters) · \(ByteCountFormatter.string(fromByteCount: record.totalDownloadBytes, countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isChosen ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(record.displayName), \(tier)")
        .accessibilityAddTraits(isChosen ? [.isSelected] : [])
    }

    private func destinationCard(icon: String, title: String, detail: String, tab: AppTab) -> some View {
        Button { leave(to: tab) } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.08)))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.8)
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.largeTitle.weight(.bold))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func body(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func calloutRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            Text(.init(text))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func downloadTitle(default first: ModelRecord?) -> String {
        guard let record = chosen ?? first else { return "Download" }
        return "Download \(record.displayName) · \(ByteCountFormatter.string(fromByteCount: record.totalDownloadBytes, countStyle: .file))"
    }

    private func tierName(_ index: Int, of count: Int) -> String {
        guard count > 1 else { return "Recommended" }
        switch index {
        case 0: return "Quickest"
        case count - 1: return "Most capable"
        default: return "Balanced"
        }
    }

    private func leave(to tab: AppTab) {
        model.completeOnboarding()
        finish(tab)
    }
}
