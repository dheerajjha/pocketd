import PocketdKit
import SwiftUI

/// Past conversations, grouped by when they happened.
///
/// Date grouping rather than a flat list because the thing people actually
/// remember about a conversation is roughly when they had it, not what they
/// called it — almost nobody titles these by hand.
///
/// A `List` and not a stack of cards, and that is a deliberate exception to the
/// rest of the app: swipe-to-delete is a system affordance with a system feel,
/// and rebuilding it by hand on a custom row gets the rubber-banding, the
/// haptics and the full-swipe wrong in ways everybody can feel and nobody can
/// name. The rows are restyled; the mechanics are the platform's. A long press
/// offers the same two actions, for anybody who never finds a swipe.
struct ConversationHistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var renaming: Conversation?
    @State private var newTitle = ""
    @State private var deleting: Conversation?

    private struct Day: Identifiable {
        var id: String { title }
        var title: String
        var conversations: [Conversation]
    }

    private var days: [Day] {
        let calendar = Calendar.current
        let now = Date()
        var buckets: [(String, [Conversation])] = [
            ("Today", []), ("Yesterday", []), ("This week", []),
            ("This month", []), ("Older", []),
        ]
        for conversation in model.history where !conversation.messages.isEmpty {
            let index: Int
            let age = calendar.dateComponents([.day], from: conversation.updatedAt, to: now).day ?? 0
            if calendar.isDateInToday(conversation.updatedAt) {
                index = 0
            } else if calendar.isDateInYesterday(conversation.updatedAt) {
                index = 1
            } else if age < 7 {
                index = 2
            } else if age < 31 {
                index = 3
            } else {
                index = 4
            }
            buckets[index].1.append(conversation)
        }
        return buckets.filter { !$0.1.isEmpty }.map { Day(title: $0.0, conversations: $0.1) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if days.isEmpty {
                    ContentUnavailableView {
                        Label("No conversations yet", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Everything you ask is kept here, on this iPhone.")
                    }
                } else {
                    list
                }
            }
            .pdCanvas()
            .navigationTitle("Past conversations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(Color.pd.canvas)
        .alert("Rename", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $newTitle)
                // An alert's field has no label of its own, and the
                // placeholder is gone the moment it holds the old name.
                .accessibilityLabel("Conversation name")
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
            Text(deleting.map { "“\($0.displayTitle)” can't be brought back." } ?? "")
        }
    }

    private var list: some View {
        List {
            ForEach(days) { day in
                Section {
                    ForEach(day.conversations) { conversation in
                        row(for: conversation)
                    }
                } header: {
                    SectionLabel(day.title)
                }
                .listRowBackground(Color.pd.card)
                .listRowSeparatorTint(Color.pd.divider)
            }
            Section {
            } footer: {
                // Teaches the gesture, which is the only way anybody finds a
                // swipe action that is not on screen.
                Text("Swipe left on a conversation, or touch and hold it, to rename or delete it.")
                    .font(Font.pd.footnote)
                    .foregroundStyle(Color.pd.inkSecondary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 56)
    }

    // MARK: - A row

    @ViewBuilder
    private func row(for conversation: Conversation) -> some View {
        let isOpen = conversation.id == model.currentConversationID
        Button {
            Task {
                await model.openConversation(conversation.id)
                dismiss()
            }
        } label: {
            HStack(spacing: PDSpacing.s) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(conversation.displayTitle)
                        .font(Font.pd.rowTitle)
                        .foregroundStyle(Color.pd.ink)
                        .lineLimit(2)
                    Text(subtitle(for: conversation, isOpen: isOpen))
                        .font(Font.pd.secondary)
                        .foregroundStyle(Color.pd.inkSecondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isOpen {
                    Image(systemName: "checkmark")
                        .font(Font.pd.secondary.weight(.semibold))
                        .foregroundStyle(Color.pd.accent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, PDSpacing.xxs)
            .contentShape(Rectangle())
        }
        // Without this the row is a Button and tints its whole label with the
        // accent colour, so every title and time reads as a link.
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deleting = conversation } label: {
                Label("Delete", systemImage: "trash")
            }
            Button { rename(conversation) } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(Color.pd.accent)
        }
        .contextMenu {
            Button { rename(conversation) } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) { deleting = conversation } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(conversation.displayTitle)
        .accessibilityValue(subtitle(for: conversation, isOpen: isOpen))
        .accessibilityHint("Opens this conversation")
    }

    private func rename(_ conversation: Conversation) {
        newTitle = conversation.title.isEmpty ? conversation.displayTitle : conversation.title
        renaming = conversation
    }

    /// When, and how much of it. Never which brain wrote it.
    private func subtitle(for conversation: Conversation, isOpen: Bool) -> String {
        let questions = conversation.messages.filter { $0.role == .user }.count
        let count = Format.counted(questions, "question")
        if isOpen { return "Open now · \(count)" }
        return "\(conversation.updatedAt.formatted(.relative(presentation: .named))) · \(count)"
    }
}
