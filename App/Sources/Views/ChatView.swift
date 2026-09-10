import SwiftUI
import PocketdKit

struct ChatView: View {
    @State private var isShowingHistory = false
    @Environment(AppModel.self) private var model
    var goTo: (AppTab) -> Void = { _ in }
    private let topAnchor = "pocketd.chat.top"

    /// When a message first appeared here. `ChatMessage` carries no clock, and
    /// within a conversation the indices only grow, so an index is a stable key
    /// for as long as the times mean anything. Messages this view did not watch
    /// arrive are simply absent rather than guessed at.
    @State private var arrived: [Int: Date] = [:]
    /// False once the reader has scrolled away from the bottom, which is the
    /// only reliable sign that they are reading something further up.
    @State private var followsStream = true
    @State private var copiedMessage: Int?
    @State private var copyTick = 0

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            VStack(spacing: 0) {
                if model.loadedModelID == nil {
                    ContentUnavailableView {
                        Label("No model loaded", systemImage: "shippingbox")
                    } description: {
                        // The wording distinguishes the two cases: telling
                        // someone to download a model they already have is
                        // its own small dead end.
                        Text(model.installed.isEmpty
                             ? "Download a model to start a conversation."
                             : "You have a model downloaded — load it to start a conversation.")
                    } actions: {
                        Button(model.installed.isEmpty ? "Browse models" : "Go to Models") {
                            goTo(.models)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Color.clear.frame(height: 0).id(topAnchor)
                            modelSwitchBanner
                            if model.conversation.isEmpty {
                                ContentUnavailableView(
                                    "Ask it something",
                                    systemImage: "bubble.left.and.bubble.right",
                                    description: Text("This runs entirely on your phone. Nothing you type leaves the device.")
                                )
                                .padding(.top, 40)
                            }
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(Array(model.conversation.enumerated()), id: \.offset) { index, message in
                                    VStack(alignment: .leading, spacing: 6) {
                                        if let stamp = timeSeparator(at: index) {
                                            Text(stamp, format: .dateTime.hour().minute())
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .frame(maxWidth: .infinity)
                                        }
                                        bubble(for: message, at: index)
                                        // Outside the bubble, at the full width
                                        // of the page. A bubble is sized for a
                                        // sentence and indented away from the
                                        // opposite margin; a card is a table,
                                        // and the 40 points a bubble gives up
                                        // are 40 points a row of times cannot
                                        // spare.
                                        ForEach(Array(message.cards.enumerated()), id: \.offset) { _, card in
                                            AnswerCardView(card: card)
                                        }
                                    }
                                    .id(index)
                                }
                            }
                            .padding()
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .onScrollGeometryChange(for: Bool.self) { geometry in
                            geometry.visibleRect.maxY >= geometry.contentSize.height - 80
                        } action: { _, isNearBottom in
                            followsStream = isNearBottom
                        }
                        .onChange(of: model.conversation.last?.content) { _, _ in
                            // Guarded: with an empty conversation this was
                            // scrollTo(-1), which left the view holding its
                            // old offset and showing a black screen with the
                            // empty state scrolled off the top.
                            guard !model.conversation.isEmpty, followsStream else { return }
                            // Unanimated on purpose. Animating each token means
                            // sixty overlapping scroll animations a second, and
                            // on a reply taller than the screen they fight each
                            // other into a visible lurch.
                            proxy.scrollTo(model.conversation.count - 1, anchor: .bottom)
                        }
                        .onChange(of: model.conversation.count) { previous, count in
                            guard count > 0 else { return }
                            stampArrivals(upTo: count, grownFrom: previous)
                            // Sending is an explicit request to be at the
                            // bottom, wherever the reader had scrolled to.
                            followsStream = true
                            withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
                        }
                        .onChange(of: model.conversation.isEmpty) { _, isEmpty in
                            if isEmpty {
                                arrived.removeAll()
                                proxy.scrollTo(topAnchor, anchor: .top)
                            }
                        }
                    }
                }

                if let error = model.generationError {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(error).font(.footnote)
                        Spacer()
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }

                composer
            }
            .sensoryFeedback(.success, trigger: copyTick)
            .navigationTitle(model.loadedModelID ?? "Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("History", systemImage: "clock.arrow.circlepath") {
                        isShowingHistory = true
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("New", systemImage: "square.and.pencil") { model.resetConversation() }
                        .disabled(model.conversation.isEmpty)
                }
            }
            .sheet(isPresented: $isShowingHistory) { ConversationHistoryView() }
        }
    }

    /// Extracted purely so the body type-checks.
    ///
    /// SwiftUI builds one expression per view body, and this one grew past
    /// what the solver will attempt — the failure is a build timeout on the
    /// enclosing `ScrollViewReader`, which points nowhere near the code that
    /// caused it.
    @ViewBuilder
    private var modelSwitchBanner: some View {
        if let notice = model.modelSwitchNotice {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text(notice).font(.footnote)
                Spacer()
                Button("OK") { model.dismissModelSwitchNotice() }
                    .font(.footnote)
            }
            .padding(10)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .padding([.horizontal, .top])
        }
    }

    @ViewBuilder
    private func bubble(for message: ChatMessage, at index: Int) -> some View {
        let isUser = message.role == .user
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        HStack(spacing: 0) {
            if isUser { Spacer(minLength: 40) }
            Group {
                if isUser {
                    // Left exactly as typed. People write literal asterisks and
                    // mean them, and a message that italicises what someone
                    // wrote is not the message they sent.
                    Text(message.content)
                } else {
                    MessageContentView(text: message.content)
                }
            }
            .textSelection(.enabled)
            .padding(10)
            .background(
                // System fills rather than a tinted grey: the assistant bubble
                // has to stay a step away from the page in both appearances,
                // and secondary/tertiary are the two the system keeps apart for
                // us when the user switches to dark.
                isUser ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground),
                in: shape
            )
            .overlay(shape.strokeBorder(isUser ? Color.accentColor.opacity(0.3) : Color.clear))
            .overlay(alignment: .topTrailing) {
                if copiedMessage == index {
                    Label("Copied", systemImage: "checkmark")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.thinMaterial, in: Capsule())
                        .padding(6)
                        .transition(.opacity)
                        // An overlay, not a row: a confirmation that changes
                        // the bubble's height moves everything below it, and
                        // this one appears while a reply is still streaming.
                        .accessibilityHidden(true)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: copiedMessage == index)
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") { copy(message, at: index) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityLabel(for: message))
            // The context menu is a long press, which VoiceOver spends on its
            // own gestures. The same copy has to exist in the actions rotor.
            .accessibilityAction(named: "Copy message") { copy(message, at: index) }
            if !isUser { Spacer(minLength: 40) }
        }
    }

    private func accessibilityLabel(for message: ChatMessage) -> String {
        if message.role == .user { return "You said" }
        return message.content.isEmpty ? "Assistant is replying" : "Assistant said"
    }

    private var composer: some View {
        @Bindable var model = model

        return HStack(spacing: 8) {
            TextField("Message", text: $model.draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .disabled(model.loadedModelID == nil)

            if model.isGenerating {
                Button("Stop", systemImage: "stop.circle.fill") { model.stopGenerating() }
                    .labelStyle(.iconOnly)
            } else {
                Button("Send", systemImage: "arrow.up.circle.fill") { model.send() }
                    .labelStyle(.iconOnly)
                    .disabled(model.draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .font(.title2)
        .padding()
        .background(.bar)
    }

    // MARK: - Timestamps

    /// Sending appends the question and the empty answer together, so a turn
    /// grows the conversation by two. A larger jump is a conversation being
    /// restored, and those messages were written whenever they were written —
    /// stamping them "now" would be the view inventing history.
    private func stampArrivals(upTo count: Int, grownFrom previous: Int) {
        guard count - previous <= 2 else { return }
        for index in 0..<count where arrived[index] == nil {
            arrived[index] = .now
        }
    }

    /// A time is worth showing where there is a gap worth noticing. Under every
    /// bubble of a conversation held in one sitting it is decoration, and the
    /// send and the reply it triggers would carry the same minute twice over.
    private func timeSeparator(at index: Int) -> Date? {
        guard let arrival = arrived[index] else { return nil }
        // An unknown neighbour is an unknown gap, which is exactly the case a
        // time answers: this is where the conversation was picked back up.
        guard index > 0, let previous = arrived[index - 1] else { return arrival }
        return arrival.timeIntervalSince(previous) >= 300 ? arrival : nil
    }

    // MARK: - Copy

    private func copy(_ message: ChatMessage, at index: Int) {
        // The cards too. The substance of an answer that ran a tool is drawn
        // rather than written, so copying the prose alone hands back "here is
        // your day" and none of the day.
        UIPasteboard.general.string = ([message.content] + message.cards.map(\.transcript))
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        copiedMessage = index
        copyTick += 1
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if copiedMessage == index { copiedMessage = nil }
        }
    }
}
