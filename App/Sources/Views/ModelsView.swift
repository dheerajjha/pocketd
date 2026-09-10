import SwiftUI
import PocketdKit

struct ModelsView: View {
    @Environment(AppModel.self) private var model
    @State private var oversizedCandidate: ModelRecord?
    @State private var deleteCandidate: ModelRecord?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Usable memory", value: format(model.budget.usableBytes))
                } footer: {
                    Text(model.budget.hasIncreasedMemoryLimit
                         ? "This build carries the increased memory limit entitlement."
                         : "Without the increased memory limit entitlement iOS caps this app well below total RAM.")
                }

                // What you have, before what you could have. With one model
                // downloaded you had to scroll past five you did not to find it.
                if !model.installed.isEmpty {
                    Section("On this phone") {
                        ForEach(model.catalog.filter { model.isInstalled($0) }) { record in
                            row(for: record)
                        }
                    }
                }
                Section(model.installed.isEmpty ? "Models" : "Available") {
                    ForEach(model.catalog.filter { !model.isInstalled($0) }) { record in
                        row(for: record)
                    }
                }
            }
            .navigationTitle("Models")
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
                        Text(record.displayName).font(.headline)
                        if record.declaredCapabilities.vision.isYes {
                            Label("Vision", systemImage: "eye")
                                .labelStyle(.titleAndIcon)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.15), in: Capsule())
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
                        Label("Loaded", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
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
