import SwiftUI
import PhotosUI
import PocketdKit

struct ChatView: View {
    @State private var isShowingHistory = false
    @FocusState private var isComposerFocused: Bool
    @State private var picked: [PhotosPickerItem] = []
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
                                        cards(for: message, at: index)
                                    }
                                    .id(index)
                                }
                            }
                            .padding()
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .contentShape(.rect)
                        .onTapGesture { isComposerFocused = false }
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

                ChatComposer(isFocused: $isComposerFocused)
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
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isComposerFocused = false }
                }
            }
        }
    }



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
            VStack(alignment: isUser ? .trailing : .leading, spacing: 8) {
                // Shown in the transcript, not just carried to the model. A
                // question about a picture is unreadable later without the
                // picture, and the conversation persists.
                if !message.images.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(message.images.enumerated()), id: \.offset) { _, data in
                            if let image = UIImage(data: data) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 104, height: 104)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                    .accessibilityLabel(
                        message.images.count == 1
                            ? "One attached photo"
                            : "\(message.images.count) attached photos"
                    )
                }

                if !message.content.isEmpty {
                    if isUser {
                        // Left exactly as typed. People write literal asterisks
                        // and mean them, and a message that italicises what
                        // someone wrote is not the message they sent.
                        Text(message.content)
                    } else {
                        MessageContentView(text: message.content)
                    }
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

    /// The cards under one message, at the full width of the page.
    ///
    /// Outside the bubble because a bubble is sized for a sentence and indented
    /// away from the opposite margin; a card is a table, and the 40 points a
    /// bubble gives up are 40 points a row of times cannot spare.
    ///
    /// Carrying the bubble's own copy affordance, because being outside it cost
    /// them that. The substance of an answer that ran a tool is here — the
    /// times, the addresses, the figures — and a long press on it did nothing,
    /// while the only long press that worked was on a visually separate object
    /// above that says none of it. `copy(_:at:)` already puts both halves on the
    /// pasteboard; only the gesture was out of reach.
    @ViewBuilder
    private func cards(for message: ChatMessage, at index: Int) -> some View {
        ForEach(Array(message.cards.enumerated()), id: \.offset) { _, card in
            AnswerCardView(card: card)
                // Lets a reader lift one row rather than the whole answer,
                // which is the same thing the bubble's own selection allows.
                .textSelection(.enabled)
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") { copy(message, at: index) }
                }
                // The context menu is a long press, which VoiceOver spends on
                // its own gestures. The same copy has to exist in the rotor.
                .accessibilityAction(named: "Copy message") { copy(message, at: index) }
        }
    }

    private func accessibilityLabel(for message: ChatMessage) -> String {
        if message.role == .user { return "You said" }
        return message.content.isEmpty ? "Assistant is replying" : "Assistant said"
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



/// The input bar, as its own view.
///
/// It is a separate `View` for one specific reason, and it is the difference
/// between a chat that types smoothly and one that locks up. SwiftUI registers
/// an observable read against whichever body performed it. While this was a
/// computed property of `ChatView`, reading `model.draft` registered against
/// `ChatView.body` — so every keystroke invalidated the whole screen and
/// re-applied the `ForEach` over the entire conversation. A sampled hang
/// showed 1371 of 1371 main-thread frames inside one `CATransaction.commit`,
/// recursing through `LazyStack.sizeThatFits`, with no inference on the stack
/// at all: the model was not slow, the layout was rebuilding itself per letter.
///
/// Keeping the draft in here means a keystroke invalidates a bar, not a
/// transcript.
private struct ChatComposer: View {
    @Environment(AppModel.self) private var model
    @FocusState.Binding var isFocused: Bool
    @State private var picked: [PhotosPickerItem] = []

    var body: some View {
        @Bindable var model = model

        return VStack(spacing: 8) {
            if !model.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(model.attachments.enumerated()), id: \.offset) { index, data in
                            thumbnail(data, at: index)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(height: 62)
            }

            HStack(spacing: 8) {
            // Offered only when the resident model can actually see. A camera
            // button on a text model is a promise the next screen breaks.
            if model.loadedModelSeesImages {
                PhotosPicker(
                    selection: $picked,
                    maxSelectionCount: 4,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Image(systemName: "photo.on.rectangle")
                }
                .disabled(model.isGenerating)
                .accessibilityLabel("Attach a photo")
            }

            TextField("Message", text: $model.draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .disabled(model.loadedModelID == nil)
                .focused($isFocused)
                .submitLabel(.send)

            if model.isGenerating {
                Button("Stop", systemImage: "stop.circle.fill") { model.stopGenerating() }
                    .labelStyle(.iconOnly)
            } else {
                Button("Send", systemImage: "arrow.up.circle.fill") { model.send() }
                    .labelStyle(.iconOnly)
                    // whitespacesAndNewlines, matching `send()` exactly.
                    // `.whitespaces` does not include newlines, so a draft of
                    // one Return left this button enabled over a `send()` that
                    // trims properly and returns immediately: the button lit
                    // up, the tap landed, and nothing happened. Two predicates
                    // deciding one question is how that happens, so they are
                    // now the same predicate.
                    .disabled(
                        model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && model.attachments.isEmpty
                    )
            }
            }
        }
        .font(.title2)
        .padding()
        .task(id: picked) { await loadPicked() }
        .background(.bar)
    }

    /// Extracted purely so the body type-checks.
    ///
    /// SwiftUI builds one expression per view body, and this one grew past
    /// what the solver will attempt — the failure is a build timeout on the
    /// enclosing `ScrollViewReader`, which points nowhere near the code that
    /// caused it.
    @ViewBuilder
    private func thumbnail(_ data: Data, at index: Int) -> some View {
        if let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) {
                    Button {
                        model.removeAttachment(at: index)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .padding(2)
                    .accessibilityLabel("Remove photo \(index + 1)")
                }
        }
    }

    /// Reads the picked items into memory and hands them to the model.
    ///
    /// Downscaled first: a modern iPhone photo is several thousand pixels wide
    /// and the projector sees a few hundred, so sending the original spends
    /// memory and encode time to produce the same tokens. It also has to be
    /// data rather than a file URL — the wire format carries base64, and a
    /// paired laptop cannot open a path on this phone.
    private func loadPicked() async {
        guard !picked.isEmpty else { return }
        for item in picked {
            guard let raw = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: raw),
                  let shrunk = image.downscaled(to: 896)?.jpegData(compressionQuality: 0.8)
            else { continue }
            model.attach(shrunk)
        }
        picked = []
    }
}

private extension UIImage {
    /// Longest edge capped, aspect preserved. Vision projectors work from a
    /// fixed small grid, so anything larger is bytes the model never reads.
    func downscaled(to longestEdge: CGFloat) -> UIImage? {
        let longest = max(size.width, size.height)
        guard longest > longestEdge else { return self }
        let scale = longestEdge / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: target).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
