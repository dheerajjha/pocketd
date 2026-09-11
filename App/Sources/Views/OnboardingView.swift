import SwiftUI
import PocketdKit

/// The first four minutes of owning this app.
///
/// Before this there was nothing: a fresh install opened on the Server tab
/// with no model, a switch that could not usefully be turned on, and no
/// statement anywhere of what the thing was for. The two questions a new
/// person actually has — *what is this* and *what do I do now* — both went
/// unanswered, and the answer to the second one is genuinely non-obvious here,
/// because the interesting half of this product is on a different machine.
///
/// So it ends somewhere no other local-LLM app can end: with the address of
/// this phone and something to paste into a laptop. PocketPal's intro finishes
/// by handing you a chat, which is right for a companion app. This is not one.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    /// Where to leave the person standing. The intro's whole job is to end
    /// somewhere useful, so the destination is the last thing it decides.
    var finish: (AppTab) -> Void

    @State private var step = 0
    @State private var chosen: ModelRecord?

    private var lastStep: Int { 4 }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch step {
                    case 0: whatThisIs
                    case 1: honestLimits
                    case 2: privacyAndNetwork
                    case 3: pickAModel
                    default: whereNext
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
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

            if step < 3 {
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
        default: "Got it"
        }
    }

    // MARK: Screens

    private var whatThisIs: some View {
        VStack(alignment: .leading, spacing: 16) {
            eyebrow("What this is")
            title("Your iPhone is the server.")
            body("""
            Language models run on this device. Then your laptop, your terminal, \
            your editor — anything on the same network — can talk to them, the \
            same way they would talk to a machine in a datacentre.
            """)
            body("""
            You can also just chat with the model here on the phone. Both work; \
            the second one is what everything else does.
            """)
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

    private var privacyAndNetwork: some View {
        VStack(alignment: .leading, spacing: 16) {
            eyebrow("Where your words go")
            title("Nothing leaves this phone.")
            body("""
            No account, no cloud, no analytics. The model runs on this device \
            and your conversations stay on it.
            """)
            // The counterweight, said in the same breath rather than buried in
            // Settings. "Private" and "reachable over the network" are both
            // true here, and only saying the first one would be a half-truth
            // about the entire point of the app.
            calloutRow(
                icon: "key.fill",
                text: "Serving other devices means they reach this phone over your network, so pocketd requires an API key by default."
            )
            calloutRow(
                icon: "list.bullet.rectangle",
                text: "Every request that arrives is listed on the Server tab, with where it came from."
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

            destinationCard(
                icon: "bubble.left.and.bubble.right.fill",
                title: "Chat on this phone",
                detail: "Like any assistant app, except offline and private.",
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
