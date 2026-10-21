import Foundation
import FlyingFox
import FlyingSocks

/// Bridges an `AsyncStream<Data>` — what a token generator naturally produces —
/// into the byte-buffered sequence FlyingFox wants for a chunked response body.
///
/// Without this the server can only send a body it has already finished
/// building, which for a language model means holding the whole completion
/// until the last token before the client sees the first. The whole point of
/// streaming is that the first token arrives in tens of milliseconds.
struct DataStreamSequence: AsyncBufferedSequence, Sendable {
    typealias Element = UInt8

    let stream: AsyncStream<Data>

    func makeAsyncIterator() -> Iterator {
        Iterator(base: stream.makeAsyncIterator())
    }

    struct Iterator: AsyncBufferedIteratorProtocol {
        typealias Element = UInt8
        typealias Buffer = Data

        var base: AsyncStream<Data>.Iterator
        var pending = Data()

        mutating func nextBuffer(suggested count: Int) async throws -> Data? {
            // Producers are allowed to yield empty chunks (a heartbeat, or a
            // token that encoded to nothing); skip them rather than reporting
            // end-of-stream, which would truncate the response.
            while pending.isEmpty {
                guard let chunk = await base.next() else { return nil }
                pending = chunk
            }
            let take = Swift.min(Swift.max(count, 1), pending.count)
            let out = pending.prefix(take)
            pending = Data(pending.dropFirst(take))
            return Data(out)
        }

        mutating func next() async throws -> UInt8? {
            guard let buffer = try await nextBuffer(suggested: 1) else { return nil }
            return buffer.first
        }
    }
}

enum ServerSentEvents {
    /// Wire framing for one SSE message. Two newlines terminate the event; one
    /// is a continuation and clients will wait forever for the second.
    static func frame(_ payload: Data) -> Data {
        var out = Data("data: ".utf8)
        out.append(payload)
        out.append(Data("\n\n".utf8))
        return out
    }

    static func frame(json object: some Encodable, encoder: JSONEncoder) throws -> Data {
        frame(try encoder.encode(object))
    }

    /// OpenAI's terminator. Ollama does not use one — it signals completion with
    /// `"done": true` on the final JSON line instead.
    static let done = Data("data: [DONE]\n\n".utf8)

    static let headers: HTTPHeaders = [
        .contentType: "text/event-stream",
        .init("Cache-Control"): "no-cache",
        .connection: "keep-alive",
        // Proxies that buffer will hold the whole completion and defeat streaming.
        .init("X-Accel-Buffering"): "no"
    ]
}

extension HTTPResponse {
    /// A chunked response whose body is produced as it is generated.
    ///
    /// The producer owns its own lifetime and outlives the client: right for a
    /// download's progress, where a laptop that hangs up should not cancel a
    /// multi-gigabyte transfer the phone is halfway through. Wrong for
    /// generation — see `streaming(headers:stoppingWhenClientLeaves:)`.
    static func streaming(
        headers: HTTPHeaders,
        producing: @escaping @Sendable (AsyncStream<Data>.Continuation) -> Void
    ) -> HTTPResponse {
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        producing(continuation)
        return HTTPResponse(
            statusCode: .ok,
            headers: headers,
            body: HTTPBodySequence(from: DataStreamSequence(stream: stream))
        )
    }

    /// A chunked response whose producer is cancelled the moment nobody is
    /// reading it any more.
    ///
    /// Every generation route used to start its own unstructured `Task` and
    /// hand it the continuation, and nothing ever told that task the client
    /// had gone. A laptop that closed the tab mid-answer left the phone
    /// generating to the last token — about 650 % CPU for 40 seconds, measured
    /// — while holding the one admission slot, so the next request got a 503.
    ///
    /// The task is owned here instead, and cancelled from the stream's
    /// termination. When FlyingFox stops reading the body (a write to the
    /// closed socket fails, or its own task is cancelled) the stream's consumer
    /// side is torn down, which terminates the stream as `.cancelled`; the
    /// producer's `for try await` over the engine then ends, which cancels the
    /// engine's own stream, which is what stops the work. Only `.cancelled`:
    /// `.finished` is the producer's own `finish()`, and cancelling it there
    /// would race the bookkeeping it still has to do — releasing the slot,
    /// closing the log entry.
    static func streaming(
        headers: HTTPHeaders,
        stoppingWhenClientLeaves producing: @escaping @Sendable (AsyncStream<Data>.Continuation) async -> Void
    ) -> HTTPResponse {
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let producer = Task { await producing(continuation) }
        continuation.onTermination = { termination in
            if case .cancelled = termination { producer.cancel() }
        }
        return HTTPResponse(
            statusCode: .ok,
            headers: headers,
            body: HTTPBodySequence(from: DataStreamSequence(stream: stream))
        )
    }
}

extension InferenceServer {
    /// nginx's "client closed request": what the log records for a streamed
    /// answer whose reader left before the end. Never sent — there is nobody
    /// left to send it to — and not a failure of the phone's.
    static let clientClosedRequest = 499
}
