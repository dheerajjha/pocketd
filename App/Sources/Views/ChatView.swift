import SwiftUI
import PocketdKit

struct ChatView: View {
    @Environment(AppModel.self) private var model
    var goTo: (AppTab) -> Void = { _ in }

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
                                    bubble(for: message).id(index)
                                }
                            }
                            .padding()
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .onChange(of: model.conversation.last?.content) { _, _ in
                            withAnimation {
                                proxy.scrollTo(model.conversation.count - 1, anchor: .bottom)
                            }
                        }
                    }
                }

                composer
            }
            .navigationTitle(model.loadedModelID ?? "Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("New", systemImage: "square.and.pencil") { model.resetConversation() }
                    .disabled(model.conversation.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func bubble(for message: ChatMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Text(message.content.isEmpty ? "…" : message.content)
                .textSelection(.enabled)
                .padding(10)
                .background(
                    message.role == .user ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            if message.role != .user { Spacer(minLength: 40) }
        }
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
}
