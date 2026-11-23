#if DEBUG && POCKETD_LIVE_PCC_PROBE && os(iOS) && !targetEnvironment(macCatalyst) && canImport(FoundationModels)
import Foundation
import FoundationModels
import Observation
import PocketdKit

/// An explicit QA launch, separate from the user's AppModel, fixture engines,
/// preferences and transcript. A run ID buys at most one attempt, even after
/// a crash. A report left at `running` is inconclusive, never a pass.
extension AppleCloudTransportProbe {
    private static let flag = "-pocketd.verifyLivePCC"
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(flag) }
    @MainActor private static var claimedLaunch = false

    @MainActor @discardableResult
    static func runIfRequested() async -> Bool {
        guard isRequested else { return false }
        guard !claimedLaunch else { return true }
        claimedLaunch = true
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1),
              let id = UUID(uuidString: args[index + 1]),
              let evidence = try? PCCLiveEvidence(id: id) else {
            print("PCC QA not started: a valid, unused run ID and writable private container are required.")
            return true
        }
        guard args.filter({ $0.hasPrefix("-pocketd.") }) == [flag] else {
            evidence.end("blocked", "conflictingLaunchFlags"); return true
        }
        guard Bundle.main.bundleIdentifier == "dev.pocketd.app", AppleCloudSigning.permitsRequests else {
            evidence.end("blocked", "signing"); return true
        }
        guard #available(iOS 27.0, *) else { evidence.end("blocked", "runtime"); return true }

        // A stalled native metadata read must not keep the test waiting or
        // later admit a prompt. The first terminal state owns the report.
        let (done, signal) = AsyncStream<Void>.makeStream()
        let worker = Task.detached(priority: .userInitiated) {
            await requestOnce(evidence)
            signal.finish()
        }
        let watchdog = Task.detached {
            try await Task.sleep(for: .seconds(60))
            evidence.end("timedOut", "deadline")
            worker.cancel()
            signal.finish()
        }
        await withTaskCancellationHandler {
            for await _ in done {}
        } onCancel: {
            evidence.end("cancelled", "callerCancelled")
            worker.cancel()
            signal.finish()
        }
        watchdog.cancel()
        return true
    }

    @available(iOS 27.0, *)
    private static func requestOnce(_ evidence: PCCLiveEvidence) async {
        guard let model = AppleCloudTransport.permittedModel else { evidence.end("blocked", "signing"); return }
        // The shared model authenticates asynchronously when first created.
        // Observe readiness under the same deadline; this sends no prompt and
        // does not poll, re-create the model, or count a queued request as a pass.
        var ready = false
        for await status in Observations({ AppleCloudTransport.nativeStatus(of: model) }) {
            guard !Task.isCancelled, evidence.noteStatus(status) else { return }
            if status == .notReady { continue }
            ready = status.canChoose
            break
        }
        guard ready else { evidence.end("blocked", "preflight"); return }

        // The production router constructs its own cloud adapter. The download
        // has no tools or model, and the on-device engine has no fallback.
        let phone = PhoneBrain(downloaded: LlamaEngine(fileURL: { _ in URL(fileURLWithPath: "/dev/null") }),
                               builtIn: SystemModelEngine())
        guard let cloud = phone.cloud as? SystemModelEngine else { evidence.end("failed", "wrongAdapter"); return }
        do {
            try Task.checkCancellation()
            let supported = try await model.supportsLocale()
            guard evidence.update({ $0.localeSupported = supported }) else { return }
            guard supported else { evidence.end("blocked", "locale"); return }
            await phone.use(.privateCloudCompute)
            try await phone.load(model: .privateCloudCompute)
            guard await phone.current == .privateCloudCompute,
                  await phone.loadedModel()?.id == ModelRecord.privateCloudComputeID else {
                _ = evidence.noteStatus(AppleCloudTransport.nativeStatus(of: model))
                evidence.end("failed", "notResident"); return
            }
            let groups = evidence.groups
            let request = GenerationRequest(modelID: ModelRecord.privateCloudComputeID,
                messages: [.user("Join these two groups in order. Reply with just the eight digits, without spaces: \(groups[0]) \(groups[1])")],
                options: .init(maxTokens: 64), origin: .onDeviceChat)
            try Task.checkCancellation()
            guard evidence.update({ $0.generateCalls += 1; $0.selectedModel = ModelRecord.privateCloudComputeID }) else { return }
            try await $didStartResponse.withValue({ type in
                let name = type == ObjectIdentifier(PrivateCloudComputeLanguageModel.self) ? "PrivateCloudComputeLanguageModel"
                    : type == ObjectIdentifier(SystemLanguageModel.self) ? "SystemLanguageModel" : "unexpected"
                _ = evidence.update { $0.nativeStarts += 1; $0.nativeModel = name }
            }) {
                var answer = ""
                var finished = false
                for try await event in try await phone.generateWithoutTools(request) {
                    try Task.checkCancellation()
                    guard !finished else { evidence.end("failed", "eventAfterTerminal"); break }
                    switch event {
                    case let .token(text):
                        let bytes = answer.utf8.count + text.utf8.count
                        guard bytes <= 256 else {
                            _ = evidence.update { $0.deliveredBytes = bytes; $0.answer = "[redacted]" }
                            evidence.end("failed", "replyTooLong"); return
                        }
                        answer += text
                        let visible = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard evidence.update({
                            $0.deliveredBytes = answer.utf8.count
                            // Only save digits of this synthetic challenge. Never save
                            // arbitrary model text, prompts, raw SDK errors or reasoning.
                            $0.answer = groups.joined().hasPrefix(visible) ? visible : "[redacted]"
                        }) else { return }
                    case .toolCallStarted, .answerCard:
                        _ = evidence.update { $0.toolEvents += 1 }
                        evidence.end("failed", "unexpectedTool"); return
                    case let .finished(reason, usage):
                        finished = true
                        _ = evidence.update {
                            $0.terminal = reason.rawValue
                            $0.promptTokens = usage.promptTokens; $0.outputTokens = usage.completionTokens
                        }
                    }
                }
                try Task.checkCancellation()
                evidence.conclude()
            }
        } catch {
            let error = (error as? InferenceError) ?? AppleCloudTransport.inferenceError(for: error)
            switch error {
            case .cancelled: evidence.end("cancelled", "requestCancelled")
            case let .privateCloud(failure, _):
                if case .limitReached = failure { _ = evidence.update { $0.quotaBlocked = true } }
                evidence.end("failed", failure.diagnosticCode)
            case .contextExhausted: evidence.end("failed", "contextExhausted")
            default: evidence.end("failed", "engineFailure")
            }
        }
        await cloud.unload()
    }
}

private final class PCCLiveEvidence: @unchecked Sendable {
    fileprivate struct Report: Encodable {
        let runID: String
        let groups: [String]
        let bundleID = Bundle.main.bundleIdentifier
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let receiptPermitsRequests = AppleCloudSigning.permitsRequests
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        #if targetEnvironment(simulator)
        let platform = "iOS Simulator"
        #else
        let platform = ProcessInfo.processInfo.isiOSAppOnMac ? "iOS app on Apple Silicon Mac" : "iOS device"
        #endif
        let startedAt = Date()
        var endedAt: Date?
        var outcome = "running", readiness = "notChecked"
        var code: String?, selectedModel: String?, nativeModel: String?, answer: String?, terminal: String?
        var quotaBlocked: Bool?, localeSupported: Bool?
        var cancellationRequested = false
        var generateCalls = 0, nativeStarts = 0, toolEvents = 0, deliveredBytes = 0
        var promptTokens: Int?, outputTokens: Int?
    }
    let groups = (0..<2).map { _ in String(Int.random(in: 1000...9999)) }
    private let lock = NSLock()
    private var report: Report
    private let file: URL

    init(id: UUID) throws {
        let fm = FileManager.default
        var dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("PCCLiveQA", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try dir.setResourceValues(values)
        let runID = id.uuidString.lowercased()
        file = dir.appendingPathComponent(runID + ".json")
        report = Report(runID: runID, groups: groups)
        // Exclusive first write is the durable admission ticket, not a previous
        // success to reuse or a failed prompt to replay after a relaunch.
        try encoded().write(to: file, options: [.withoutOverwriting, .completeFileProtection])
    }

    private func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(report)
    }

    fileprivate func update(_ change: (inout Report) -> Void) -> Bool {
        lock.withLock {
            guard report.outcome == "running" else { return false }
            change(&report)
            if report.outcome != "running" { report.endedAt = Date() }
            do {
                let data = try encoded()
                try data.write(to: file, options: [.atomic, .completeFileProtection])
                // Launch Services can redirect stdout into the private QA run
                // directory. Mirroring only this already-saved, sanitized final
                // record avoids requesting access to another Mac app's container.
                if ProcessInfo.processInfo.isiOSAppOnMac, report.outcome != "running" {
                    var line = Data("POCKETD_PCC_QA_FINAL ".utf8)
                    line.append(data); line.append(10)
                    try? FileHandle.standardOutput.write(contentsOf: line)
                }
                return true
            }
            catch { report.outcome = "failed"; return false }
        }
    }

    func noteStatus(_ status: AppleCloudStatus) -> Bool {
        update {
            switch status {
            case .notReady: $0.readiness = "notReady"; $0.quotaBlocked = nil
            case .unavailable: $0.readiness = "unavailable"; $0.quotaBlocked = nil
            case .available: $0.readiness = "available"; $0.quotaBlocked = false
            case .approachingLimit: $0.readiness = "approachingLimit"; $0.quotaBlocked = false
            case .limitReached: $0.readiness = "limitReached"; $0.quotaBlocked = true
            }
        }
    }

    func end(_ outcome: String, _ code: String) {
        _ = update {
            $0.outcome = outcome; $0.code = code
            $0.cancellationRequested = code == "deadline" || code == "callerCancelled"
        }
    }

    func conclude() {
        _ = update {
            if $0.terminal == FinishReason.cancelled.rawValue { $0.outcome = "cancelled"; $0.code = "terminalCancelled" }
            else if $0.terminal != FinishReason.stop.rawValue { $0.outcome = "failed"; $0.code = "noNormalTerminal" }
            else if $0.nativeStarts != 1 || $0.nativeModel != "PrivateCloudComputeLanguageModel" {
                $0.outcome = "failed"; $0.code = "wrongBindingCountOrType"
            } else if $0.generateCalls != 1 || $0.toolEvents != 0 || $0.answer != $0.groups.joined() {
                $0.outcome = "failed"; $0.code = "challengeMismatch"
            } else { $0.outcome = "passed" }
        }
    }
}
#endif
