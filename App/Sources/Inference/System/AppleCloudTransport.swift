import Foundation
import PocketdKit
#if canImport(FoundationModels)
import FoundationModels
#endif

extension SystemModelEngine {
    nonisolated static var cloudStatus: AppleCloudStatus {
        #if canImport(FoundationModels)
        if #available(iOS 27.0, *), let model = AppleCloudTransport.permittedModel {
            return AppleCloudTransport.nativeStatus(of: model)
        }
        #endif
        return .unavailable
    }

    /// Picker readiness includes the current language. `availability` alone
    /// does not answer that question. Metadata checks never send chat content.
    nonisolated static func checkedCloudStatus() async -> AppleCloudStatus {
        #if canImport(FoundationModels)
        if #available(iOS 27.0, *), let model = AppleCloudTransport.permittedModel {
            let status = AppleCloudTransport.nativeStatus(of: model)
            guard status.canChoose else { return status }
            do {
                guard try await model.supportsLocale() else { return .unavailable }
                return AppleCloudTransport.nativeStatus(of: model)
            } catch {
                let latest = AppleCloudTransport.nativeStatus(of: model)
                return latest.canChoose ? .notReady : latest
            }
        }
        #endif
        return .unavailable
    }
}

#if canImport(FoundationModels)
@available(iOS 27.0, *)
enum AppleCloudTransport {
    // Read the signed capability BEFORE touching this lazy instance. Apple's
    // native availability can be .available in a build that would trap on its
    // first prompt. Share the model (and its quota); never share a transcript.
    private static let sharedModel = PrivateCloudComputeLanguageModel()

    static var permittedModel: PrivateCloudComputeLanguageModel? {
        guard AppleCloudSigning.permitsRequests else { return nil }
        return sharedModel
    }

    static func nativeStatus(of model: PrivateCloudComputeLanguageModel) -> AppleCloudStatus {
        switch model.availability {
        case .unavailable(.systemNotReady): return .notReady
        case .unavailable: return .unavailable
        case .available:
            let quota = model.quotaUsage
            switch quota.status {
            case let .belowLimit(info): return info.isApproachingLimit ? .approachingLimit : .available
            case .limitReached: return .limitReached(reset: quota.resetDate)
            @unknown default: return .unavailable
            }
        }
    }

    /// No tools, prewarming or generation in this preflight. A metadata read
    /// can itself fail offline; don't read the person's day in that case.
    static func prepare() async throws(InferenceError) -> AppleRequestModel {
        guard let model = permittedModel else { throw InferenceError.privateCloud(.unavailable) }
        let result: Result<AppleRequestModel, InferenceError>? = await SystemToolRun.withDeadline(.seconds(12)) {
            do { return .success(try await metadata(for: model)) }
            catch { return .failure(inferenceError(for: error)) }
        }
        guard !Task.isCancelled else { throw InferenceError.cancelled }
        guard let result else { throw InferenceError.privateCloud(.timedOut) }
        return try result.get()
    }

    private static func metadata(for model: PrivateCloudComputeLanguageModel) async throws -> AppleRequestModel {
        func checkStatus() throws {
            try Task.checkCancellation()
            if let failure = AppleCloudFailure(blocking: nativeStatus(of: model)) {
                throw InferenceError.privateCloud(failure)
            }
        }
        try checkStatus()
        guard try await model.supportsLocale() else { throw InferenceError.privateCloud(.unsupportedLanguage) }
        try Task.checkCancellation()
        let size = try await model.contextSize
        guard size > 0 else { throw InferenceError.privateCloud(.notReady) }
        try checkStatus()
        return AppleRequestModel(cloud: model, contextSize: size)
    }

    static func inferenceError(for error: any Error, afterWrite: Bool = false) -> InferenceError {
        if Task.isCancelled || error is CancellationError { return .cancelled }
        if let error = error as? InferenceError {
            switch error {
            case let .privateCloud(reason, started): return .privateCloud(reason, afterWrite: started || afterWrite)
            case .cancelled: return .cancelled
            case .contextExhausted: return afterWrite ? .privateCloud(.contextExceeded, afterWrite: true) : .contextExhausted
            default: return .privateCloud(.other, afterWrite: afterWrite)
            }
        }
        let reason: AppleCloudFailure
        if let error = error as? PrivateCloudComputeLanguageModel.Error {
            switch error {
            case .networkFailure: reason = .network
            case let .quotaLimitReached(info): reason = .limitReached(reset: info.resetDate)
            case .serviceUnavailable: reason = .serviceUnavailable
            @unknown default: reason = .other
            }
        } else if let error = error as? URLError {
            switch error.code {
            case .cancelled: return .cancelled
            case .timedOut: reason = .timedOut
            default: reason = .network
            }
        } else {
            switch SystemModelEngine.failure(for: error) {
            case .contextExceeded:
                if !afterWrite { return .contextExhausted }
                reason = .contextExceeded
            case .guardrail, .refusal: reason = .refused
            case .rateLimited, .busy: reason = .busy
            case .timedOut: reason = .timedOut
            case .unsupportedLanguage: reason = .unsupportedLanguage
            default: reason = .other
            }
        }
        return .privateCloud(reason, afterWrite: afterWrite)
    }
}

/// The model selected for this request owns both its budget and its session
/// initializer. Neither the read-first path nor the tool path picks a model.
@available(iOS 26.0, *)
struct AppleRequestModel: Sendable {
    typealias BoundSession = (session: LanguageModelSession, modelType: ObjectIdentifier)
    let onDevice: SystemLanguageModel?
    var isCloud: Bool { onDevice == nil }
    let budget: SystemModelBudget
    let makeSession: @Sendable ([any Tool], Transcript) -> BoundSession

    init(onDevice model: SystemLanguageModel) {
        onDevice = model
        budget = SystemModelBudget(contextTokens: SystemModelEngine.contextTokens)
        makeSession = Self.bind(model, LanguageModelSession.init(model:tools:transcript:))
    }

    @available(iOS 27.0, *)
    fileprivate init(cloud model: PrivateCloudComputeLanguageModel, contextSize: Int) {
        onDevice = nil
        // PCC has no tokenCount API. Use the Kit's UTF-8 estimate, keep the
        // output/tool reserves, and let long conversations use its own window.
        budget = SystemModelBudget(
            contextTokens: contextSize, responseTokens: min(4096, contextSize / 4), historyTokens: contextSize
        )
        makeSession = Self.bind(model, LanguageModelSession.init(model:tools:transcript:))
    }

    private static func bind<M: Sendable>(
        _ model: M,
        _ build: @escaping @Sendable (M, [any Tool], Transcript) -> LanguageModelSession
    ) -> @Sendable ([any Tool], Transcript) -> BoundSession {
        { tools, transcript in
            (build(model, tools, transcript), ObjectIdentifier(M.self))
        }
    }
}
#endif
