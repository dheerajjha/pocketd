import PocketdKit
import SwiftUI

/// What "+" on Routines offers: the four routines people want, and Custom.
///
/// One tap adds a template with its own defaults — 7:30 on weekdays for the
/// morning brief — and the card appears; changing the hour is a tap on the
/// card. v2 opened a full editor from every template instead, which turned
/// "yes, that one" into a form.
///
/// A template already on this phone is not offered twice. Its row says when it
/// is set for and opens that routine, because a second "Morning brief" at the
/// same minute is almost always a person who forgot they had the first one.
/// Somebody who really wants two briefs makes the second with Custom.
struct RoutineTemplateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ProStore.self) private var pro: ProStore?

    /// The routine a template already has, if any.
    let existing: (RoutineTemplate) -> ScheduledTask?
    /// Adds the template's routine. The sheet is closed by the caller once it
    /// has been saved.
    let add: (RoutineTemplate) -> Void
    /// Edits a routine — an existing one, or Custom's blank one.
    let open: (RoutineDraft) -> Void

    @State private var adding: RoutineTemplate?
    @State private var notificationsUndecided = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PDSpacing.s) {
                    PDCard(padding: PDSpacing.xs) {
                        VStack(spacing: 0) {
                            ForEach(Array(RoutineTemplate.offered.enumerated()), id: \.element) { index, template in
                                if index > 0 { divider }
                                templateRow(template)
                            }
                            divider
                            customRow
                        }
                    }
                    if notificationsUndecided {
                        // The first routine is what asks iOS for
                        // notifications; this is the warning that it will.
                        Primer("Next, tap **Allow** so Pocketd can tell you when it's ready.", symbol: "bell")
                            .padding(.horizontal, PDSpacing.xxs)
                    }
                }
                .padding(.horizontal, PDSpacing.gutter)
                .padding(.top, PDSpacing.xs)
                .padding(.bottom, PDSpacing.l)
            }
            .scrollIndicators(.hidden)
            .pdCanvas()
            .navigationTitle("Add a routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            notificationsUndecided = await NotificationCentre.shared.authorizationStatus() == .notDetermined
        }
    }

    private func templateRow(_ template: RoutineTemplate) -> some View {
        let current = existing(template)
        // Adding a Pro template is Pocketd Pro; one already on this phone —
        // made before Pro, or on an early supporter's — opens for anyone.
        let gated = current == nil && template.needsPro
        let locked = gated && ProBadge.status(for: pro) != nil
        return ProGateButton(.routines, gated: gated) {
            if let current {
                open(RoutineDraft(current))
            } else if adding == nil {
                adding = template
                add(template)
            }
        } label: {
            HStack(alignment: .center, spacing: PDSpacing.s) {
                IconTile.small(template.symbolName)
                VStack(alignment: .leading, spacing: 2) {
                    ProBadgedTitle(showsBadge: gated) {
                        Text(template.title)
                            .font(Font.pd.rowTitle)
                            .foregroundStyle(Color.pd.ink)
                    }
                    Text(current.map { "Set · \(ScheduleWords.recurrence($0.recurrence))" } ?? template.blurb)
                        .font(Font.pd.secondary)
                        .foregroundStyle(Color.pd.inkSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: PDSpacing.xs)
                trailing(for: template, isSet: current != nil)
            }
            .padding(.horizontal, PDSpacing.s)
            .padding(.vertical, PDSpacing.s)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(PDPressStyle())
        .accessibilityLabel(
            (current.map { "\(template.title), already set. \(ScheduleWords.recurrence($0.recurrence))" }
                ?? "Add \(template.title). \(template.blurb)") + (locked ? " \(ProCopy.badgeSpoken)." : "")
        )
        .accessibilityHint(current == nil ? "Adds it with the usual time" : "Opens it")
    }

    @ViewBuilder
    private func trailing(for template: RoutineTemplate, isSet: Bool) -> some View {
        if adding == template {
            ProgressView()
                .frame(width: 28, height: 28)
        } else if isSet {
            Image(systemName: "checkmark")
                .font(Font.pd.rowTitle)
                .foregroundStyle(Color.pd.positive)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "plus.circle.fill")
                .font(.system(.title2))
                .foregroundStyle(Color.pd.ink)
                .accessibilityHidden(true)
        }
    }

    private var customRow: some View {
        // A routine of one's own is Pocketd Pro. The editor asks again on
        // Save, for a free routine turned into something else.
        ProGateButton(.routines) {
            open(RoutineDraft())
        } label: {
            HStack(alignment: .center, spacing: PDSpacing.s) {
                IconTile.small("slider.horizontal.3")
                VStack(alignment: .leading, spacing: 2) {
                    ProBadgedTitle {
                        Text("Custom")
                            .font(Font.pd.rowTitle)
                            .foregroundStyle(Color.pd.ink)
                    }
                    Text("Your own name, time and days.")
                        .font(Font.pd.secondary)
                        .foregroundStyle(Color.pd.inkSecondary)
                }
                Spacer(minLength: PDSpacing.xs)
                Image(systemName: "chevron.right")
                    .font(Font.pd.chevron)
                    .foregroundStyle(Color.pd.inkTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, PDSpacing.s)
            .padding(.vertical, PDSpacing.s)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(PDPressStyle())
        .accessibilityHint("Opens a new routine to fill in")
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.pd.divider)
            .frame(height: 1)
            .padding(.leading, PDSpacing.s + PDMetric.iconTileSmall + PDSpacing.s)
    }
}
