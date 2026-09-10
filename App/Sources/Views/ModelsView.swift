import SwiftUI
import PocketdKit

struct ModelsView: View {
    @Environment(AppModel.self) private var model
    @State private var isSearching = false
    @State private var showInstalled = true
    @State private var showAvailable = true
    @State private var oversizedCandidate: ModelRecord?
    @State private var deleteCandidate: ModelRecord?

    var body: some View {
        NavigationStack {
            List {
                if let notice = model.offloadNotice {
                    Section {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "memorychip")
                                .foregroundStyle(.green)
                            Text(notice).font(.callout)
                            Spacer()
                            Button("OK") { model.dismissOffloadNotice() }
                                .font(.caption)
                        }
                    }
                }

                Section {
                    LabeledContent("Usable memory", value: format(model.budget.usableBytes))
                } footer: {
                    Text(model.budget.hasIncreasedMemoryLimit
                         ? "This build carries the increased memory limit entitlement."
                         : "Without the increased memory limit entitlement iOS caps this app well below total RAM.")
                }

                // What you have, before what you could have. With one model
                // downloaded you had to scroll past five you did not to find it.
                //
                // Both sections collapse, because the two halves are wanted at
                // different times: while choosing a model the catalogue matters
                // and while using one it is noise between you and the row you
                // came for.
                // Collapsed by hiding the rows rather than with
                // `Section(isExpanded:)`, which only honours its binding under
                // `.listStyle(.sidebar)` — and that would both restyle the
                // whole screen and draw a second chevron next to this one.
                if !model.installed.isEmpty {
                    Section {
                        if showInstalled {
                            ForEach(model.catalog.filter { model.isInstalled($0) }) { record in
                                row(for: record)
                            }
                        }
                    } header: {
                        sectionHeader("Ready to use", isExpanded: $showInstalled)
                    }
                }
                Section {
                    if showAvailable {
                        ForEach(model.catalog.filter { !model.isInstalled($0) }) { record in
                            row(for: record)
                        }
                    }
                } header: {
                    sectionHeader(
                        model.installed.isEmpty ? "Models" : "Available to download",
                        isExpanded: $showAvailable
                    )
                } footer: {
                    if showAvailable {
                        Text("These are known to load on a phone. Tap + to search Hugging Face for anything else.")
                    }
                }
            }
            .navigationTitle("Models")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { isSearching = true } label: {
                        Label("Find more models", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isSearching) { ModelSearchView() }
            .confirmationDialog(
                "This model is larger than this device can hold",
                isPresented: Binding(
                    get: { oversizedCandidate != nil },
                    set: { if !$0 { oversizedCandidate = nil } }
                ),
                titleVisibility: .visible,
                presenting: oversizedCandidate
            ) { record in
                Button("Download anyway", role: .destructive) {
                    model.download(record, allowingOversized: true)
                    oversizedCandidate = nil
                }
                Button("Cancel", role: .cancel) { oversizedCandidate = nil }
            } message: { record in
                Text("\(record.displayName) needs about \(format(record.estimatedResidentBytes)) resident and iOS allows this app roughly \(format(model.budget.usableBytes)). It will most likely be killed while loading.")
            }
            .confirmationDialog(
                "Delete this model?",
                isPresented: Binding(
                    get: { deleteCandidate != nil },
                    set: { if !$0 { deleteCandidate = nil } }
                ),
                titleVisibility: .visible,
                presenting: deleteCandidate
            ) { record in
                Button("Delete", role: .destructive) {
                    Task { await model.delete(record) }
                    deleteCandidate = nil
                }
                Button("Cancel", role: .cancel) { deleteCandidate = nil }
            } message: { record in
                // Delete sits a few points from Load, and the download it
                // discards took minutes.
                Text(model.loadedModelID == record.id
                     ? "\(record.displayName) is currently loaded. Deleting it unloads it and frees \(format(record.totalDownloadBytes)), which has to be downloaded again to use it."
                     : "Frees \(format(record.totalDownloadBytes)). It has to be downloaded again to use it.")
            }
        }
    }

    @ViewBuilder
    private func row(for record: ModelRecord) -> some View {
        let fit = model.fit(for: record)
        let installed = model.isInstalled(record)
        let progress = model.downloads[record.id]

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        // Glyph rather than a word: it reads at a glance down a
                        // list, and the list is scanned far more often than any
                        // single row is read.
                        Image(systemName: record.declaredCapabilities.vision.isYes
                              ? "eye" : "text.bubble")
                            .font(.caption)
                            .foregroundStyle(record.declaredCapabilities.vision.isYes ? .purple : .blue)
                            .accessibilityLabel(record.declaredCapabilities.vision.isYes
                                                ? "Understands images" : "Text only")
                        Text(record.displayName).font(.headline)
                        if model.loadedModelID == record.id {
                            Circle()
                                .fill(.green)
                                .frame(width: 7, height: 7)
                                .accessibilityLabel("Loaded")
                        }
                    }
                    // The total, not the weights alone: a vision model's
                    // projector is another download and another few hundred
                    // megabytes resident.
                    Text("\(record.parameters) · \(record.quantization) · \(format(record.totalDownloadBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                badge(for: fit)
            }

            fitExplanation(for: fit)

            if let progress {
                ProgressView(value: progress.fraction) {
                    Text("\(format(progress.receivedBytes)) of \(format(progress.totalBytes))")
                        .font(.caption)
                }
                Button("Cancel", role: .cancel) { model.cancelDownload(record) }
                    .font(.caption)
            } else if installed {
                HStack {
                    if model.loadingModelID == record.id {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Loading…").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if model.loadedModelID == record.id {
                        // Just the button. Adding it left the row saying the
                        // same thing three times — a dot beside the name, a
                        // green tick, and the word "Loaded" — for a state that
                        // "Offload" already implies, since nothing else can be
                        // offloaded. The dot beside the name is what scans down
                        // a list; this is what you press.
                        Button("Offload") { Task { await model.offloadModel() } }
                            .buttonStyle(.bordered)
                            .font(.caption)
                            .accessibilityLabel("Offload \(record.displayName)")
                            .accessibilityHint("Frees the memory this model is using. The file stays on this phone.")
                    } else {
                        Button("Load") { Task { await model.loadModel(record) } }
                            .buttonStyle(.bordered)
                            .disabled(model.isLoadingModel)
                    }
                    Spacer()
                    Button("Delete", role: .destructive) { deleteCandidate = record }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            } else {
                Button("Download") {
                    // The estimate is a heuristic, so it warns rather than
                    // forbids — but it makes the consequence explicit first.
                    if fit.allowsDownload {
                        model.download(record)
                    } else {
                        oversizedCandidate = record
                    }
                }
                .buttonStyle(.bordered)
            }

            if let paused = model.downloadPaused[record.id] {
                Text(paused).font(.caption2).foregroundStyle(.orange)
                Button("Discard partial download", role: .destructive) {
                    Task { await model.discardPartialDownload(record) }
                }
                .font(.caption2)
            }

            if let error = model.downloadErrors[record.id] {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, isExpanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(.snappy) { isExpanded.wrappedValue.toggle() }
        } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 0 : -90))
                    .font(.caption2)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded.wrappedValue ? "Expanded" : "Collapsed")
        .accessibilityHint("Double tap to \(isExpanded.wrappedValue ? "collapse" : "expand")")
    }

    /// The consequence of the fit, spelled out.
    ///
    /// A one-word badge reading "Tight" or "Too large" says which bucket the
    /// model landed in and nothing about what happens next, which is the only
    /// part anyone needs at the moment of deciding whether to spend a gigabyte
    /// of bandwidth on it.
    @ViewBuilder
    private func fitExplanation(for fit: DeviceBudget.Fit) -> some View {
        switch fit {
        case .comfortable:
            EmptyView()
        case .tight:
            Label(
                "Loads, but leaves little room for context. Long conversations may be refused.",
                systemImage: "exclamationmark.circle"
            )
            .font(.caption2)
            .foregroundStyle(.orange)
        case .willNotFit:
            Label(
                "Larger than this phone can hold. iOS would stop the app while loading it.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption2)
            .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func badge(for fit: DeviceBudget.Fit) -> some View {
        switch fit {
        case .comfortable:
            Text("Fits").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                .background(.green.opacity(0.15), in: Capsule())
        case .tight:
            Text("Tight").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                .background(.orange.opacity(0.15), in: Capsule())
        case .willNotFit:
            Text("Too large").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                .background(.red.opacity(0.15), in: Capsule())
        }
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
