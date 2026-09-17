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
/// name. The rows are restyled; the mechanics are the platform's.
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
        return buckets.filter { !$0.1.isEmpty }.map { Day(title: $0.0, conversations: $0.1) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.history.isEmpty {
                empty
            } else {
                list
            }
        }
        .pdCanvas()
        .presentationDragIndicator(.visible)
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

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: PDSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("History")
                    .font(Font.pd.titleDetail)
                    .tracking(-0.4)
                    .foregroundStyle(Color.pd.ink)
                Spacer(minLength: 0)
                CircleIconButton(symbol: "xmark", label: "Close") { dismiss() }
            }
            if !model.history.isEmpty {
                // Teaches the gesture, which is the only way anybody finds a
                // swipe action that is not on screen.
                Text("Swipe a conversation to rename or delete it.")
                    .pdSubtitle()
            }
        }
        .padding(.horizontal, PDSpacing.gutter)
        .padding(.top, PDSpacing.l)
        .padding(.bottom, PDSpacing.s)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: PDSpacing.cardGap) {
            PDCard {
                VStack(alignment: .leading, spacing: PDSpacing.s) {
                    IconTile.small("bubble.left.and.bubble.right")
                    Text("Nothing here yet.")
                        .font(Font.pd.headline)
                        .foregroundStyle(Color.pd.ink)
                    Text("Every conversation is saved on this phone automatically, and survives closing the app.")
                        .pdBody()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PDSpacing.gutter)
        .padding(.top, PDSpacing.s)
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
                        .padding(.bottom, PDSpacing.xxs)
                }
                .listRowBackground(Color.pd.card)
                .listRowSeparatorTint(Color.pd.divider)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .environment(\.defaultMinListRowHeight, 56)
    }

    // MARK: - A row

    @ViewBuilder
    private func row(for conversation: Conversation) -> some View {
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
                        .lineLimit(1)
                    Text(subtitle(for: conversation))
                        .font(Font.pd.caption)
                        .foregroundStyle(Color.pd.inkSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: PDSpacing.xxs)
                if conversation.id == model.currentConversationID {
                    StatusPill(.positive, "Open")
                }
            }
            .padding(.vertical, PDSpacing.xxs)
            .contentShape(Rectangle())
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
            .tint(Color.pd.accent)
        }
        .accessibilityLabel("\(conversation.displayTitle), \(conversation.messages.count) messages")
    }

    /// When, and how much of it.
    ///
    /// Not which model wrote it. The id is a filename — lowercase, hyphenated,
    /// and often the brand name of somebody else's product — and the one screen
    /// where naming the resident model earns its place is the chip on Ask that
    /// says what is answering right now.
    private func subtitle(for conversation: Conversation) -> String {
        let when = conversation.updatedAt.formatted(.relative(presentation: .named))
        let count = conversation.messages.count
        return "\(when) · \(count) message\(count == 1 ? "" : "s")"
    }
}
