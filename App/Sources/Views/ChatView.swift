import SwiftUI
import PocketdKit

struct ChatView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            VStack(spacing: 0) {
                if model.loadedModelID == nil {
                    ContentUnavailableView(
                        "No model loaded",
                        systemImage: "shippingbox",
                        description: Text("Download and load a model from the Models tab.")
                    )
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(Array(model.conversation.enumerated()), id: \.offset) { index, message in
                                    bubble(for: message).id(index)
                                }
                            }
                            .padding()
                        }
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
