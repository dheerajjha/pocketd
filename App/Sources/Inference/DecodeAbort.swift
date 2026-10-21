import Foundation
import Synchronization
import LocalLLMClientLlama
import llama

/// A switch llama.cpp reads while it computes, so Stop stops.
///
/// Without one, nothing could interrupt the engine once it had started, and
/// the walkthrough measured what that costs: Stop on a reply that had been
/// "Thinking…" for nine minutes left the process at ~800% CPU for more than
/// five minutes more, through a brain switch, and every answer after it
/// crawled. Two holes, both in code this app does not own:
///
/// - **Prompt processing never looks at cancellation.** LocalLLMClient's
///   `textStream(from:)` decodes the whole prompt synchronously, 512 tokens per
///   `llama_decode`, before it returns a single token. A task cancelled during
///   it finds out only when it is over — on the simulator's CPU, minutes for a
///   long conversation.
/// - **The tool path's decode loop is an orphan.** `LlamaClient.responseStream`
///   drives the token generator from an unstructured `Task` and gives the
///   stream it returns no `onTermination`. Stop ends our loop; that task keeps
///   decoding until the model says end-of-text or the window is full, holding
///   the old weights alive while the next brain loads beside them. Its
///   generator checks `Task.isCancelled`, but it is checking a task nobody
///   ever cancels.
///
/// llama.cpp has an answer to both: an abort callback on the context, read by
/// the CPU backend between graph nodes and by the Metal path at the CPU split
/// that opens every decode. Return true and `llama_decode` gives up with status
/// 2, LocalLLMClient throws, and whichever task was driving it — ours, or the
/// orphan — ends at its next step. On the simulator that is milliseconds; on a
/// phone's GPU, at most the batch already in flight.
///
/// The switch is sticky. A tripped switch aborts every later decode on that
/// context, which is what kills the orphan however late it next tries, and is
/// why a tripped context is never reused: the engine rebuilds the client
/// before the next request, exactly as it already did after a cancellation
/// left the caches half-written.
final class DecodeAbort: Sendable {
    private let tripped = Atomic<Bool>(false)

    func trip() { tripped.store(true, ordering: .relaxed) }

    var isTripped: Bool { tripped.load(ordering: .relaxed) }

    /// Hands this switch to `client`'s `llama_context`.
    ///
    /// Returns false when the context cannot be found, which means a
    /// LocalLLMClient upgrade renamed what is read below — the engine still
    /// works, and Stop is back to stopping at the next token instead of
    /// mid-decode. Called once per client, before anything decodes with it.
    ///
    /// The context is reached by reflection because nothing else reaches it:
    /// `LlamaClient.context` is `private`, `Context.context` is `package`, and
    /// the only accessor (`_context`) exists in the library's own DEBUG builds.
    /// `Mirror` reads stored properties whatever their access level, in Release
    /// as in Debug, and a wrong guess here costs the abort, never memory: the
    /// result is type-checked before it is used.
    ///
    /// The switch is retained on llama.cpp's behalf and never released. The
    /// context can outlive the engine's reference to it — the orphaned decode
    /// task above holds it — and a callback reading a freed switch would be a
    /// crash inside a C++ compute loop. One small object per client build is
    /// the price.
    @discardableResult
    func install(on client: LlamaClient) -> Bool {
        guard let context = Mirror(reflecting: client).descendant("context") as? LocalLLMClientLlama.Context,
              let pointer = Mirror(reflecting: context).descendant("context") as? OpaquePointer
        else { return false }
        let retained = Unmanaged.passRetained(self).toOpaque()
        llama_set_abort_callback(pointer, { data in
            guard let data else { return false }
            return Unmanaged<DecodeAbort>.fromOpaque(data).takeUnretainedValue().isTripped
        }, retained)
        return true
    }
}
