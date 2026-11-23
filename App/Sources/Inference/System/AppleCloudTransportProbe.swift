#if DEBUG && canImport(FoundationModels)
import Foundation

/// A test can scope `$didStartResponse.withValue` around `generate`, collecting
/// ObjectIdentifier(SystemLanguageModel.self) or
/// ObjectIdentifier(PrivateCloudComputeLanguageModel.self). The witness comes
/// from the actual SDK initializer argument and fires at streamResponse, even
/// when it later throws. Zero starts means preflight stopped the request.
/// Observes only; it cannot change a model, its status, or a stream's result.
enum AppleCloudTransportProbe {
    @TaskLocal static var didStartResponse: (@Sendable (ObjectIdentifier) -> Void)?
}
#endif
