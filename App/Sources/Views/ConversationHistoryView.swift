import SwiftUI
import PocketdKit

/// Past conversations, grouped by when they happened.
///
/// Date grouping rather than a flat list because the thing people actually
/// remember about a conversation is roughly when they had it, not what they
/// called it — almost nobody titles these by hand.
struct ConversationHistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var renaming: Conversation?
    @State private var newTitle = ""
    @State private var deleting: Conversation?

    private struct Group: Identifiable {
        var id: String { title }
        var title: String
        var conversations: [Conversation]
    }

    private var groups: [Group] {
        let calendar = Calendar.current
        let now = Date()
        var buckets: [(String, [Conversation])] = [
            ("Today", []), ("Yesterday", []), ("This week", []),
            ("This month", []), ("Older", [])
        ]
        for conversation in model.history {
            let index: Int
            if calendar.isDateInToday(conversation.updatedAt) {
                index = 0
            } else if calendar.isDateInYesterday(conversation.updatedAt) {
                index = 1
            } else if let days = calendar.dateComponents([.day], from: conversation.updatedAt, to: now).day, days < 7 {
                index = 2
            } else if let days = calendar.dateComponents([.day], from: conversation.updatedAt, to: now).day, days < 31 {
                index = 3
            } else {
                index = 4
            }
            buckets[index].1.append(conversation)
        }
        return buckets.filter { !$0.1.isEmpty }.map { Group(title: $0.0, conversations: $0.1) }
    }

    var body: some View {
        NavigationStack {
            List {
                if model.history.isEmpty {
                    ContentUnavailableView(
                        "No conversations yet",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Anything you say in Chat is saved here automatically, and survives closing the app.")
                    )
                } else {
                    ForEach(groups) { group in
                        Section(group.title) {
                            ForEach(group.conversations) { conversation in
                                row(for: conversation)
                            }
                        }
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task {
                            await model.newConversation()
                            dismiss()
                        }
                    } label: {
                        Label("New", systemImage: "square.and.pencil")
                    }
                }
            }
            .alert("Rename", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("Title", text: $newTitle)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") {
                    if let target = renaming {
                        Task { await model.renameConversation(target.id, to: newTitle) }
                    }
                    renaming = nil
                }
            }
            .confirmationDialog(
                "Delete this conversation?",
                isPresented: Binding(
                    get: { deleting != nil },
                    set: { if !$0 { deleting = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let target = deleting {
                        Task { await model.deleteConversation(target.id) }
                    }
                    deleting = nil
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: {
                // Named, because "are you sure" on an unnamed row is a question
                // nobody can answer.
                Text(deleting.map { "\($0.displayTitle) cannot be recovered." } ?? "")
            }
        }
    }

    @ViewBuilder
    private func row(for conversation: Conversation) -> some View {
        Button {
            Task {
                await model.openConversation(conversation.id)
                dismiss()
            }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(conversation.displayTitle)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(conversation.updatedAt, format: .relative(presentation: .named))
                        if let modelID = conversation.modelID {
                            Text("·")
                            // Which model wrote it. On this app the resident
                            // model can change underneath a conversation when a
                            // request arrives from another device, so the
                            // transcript is not evidence about one model unless
                            // it says which.
                            Text(modelID).lineLimit(1)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if conversation.id == model.currentConversationID {
                    Text("Open")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: Capsule())
                }
            }
        }
        // Without this the row is a Button and tints its whole label with the
        // accent colour, so every title and timestamp reads as a link.
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deleting = conversation } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                newTitle = conversation.title.isEmpty ? conversation.displayTitle : conversation.title
                renaming = conversation
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.indigo)
        }
        .accessibilityLabel("\(conversation.displayTitle), \(conversation.messages.count) messages")
    }
}
