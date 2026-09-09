import Foundation
import FlyingFox

extension InferenceServer {
    func handleListModels(_ request: HTTPRequest) async -> HTTPResponse {
        let cors = corsHeaders()
        if let rejection = authorize(request) { return rejection }
        let created = Int(Date().timeIntervalSince1970)
        let list = OpenAI.ModelList(
            data: await models().map {
                OpenAI.Model(id: $0.id, created: created, owned_by: "pocketd")
            }
        )
        return jsonResponse(list, headers: cors)
    }

    func handleRetrieveModel(_ request: HTTPRequest) async -> HTTPResponse {
        let cors = corsHeaders()
        if let rejection = authorize(request) { return rejection }
        let id = request.path.split(separator: "/").last.map(String.init) ?? ""
        guard let model = await models().first(where: { $0.id == id }) else {
            return errorResponse(
                status: .notFound,
                message: "Model '\(id)' is not installed.",
                type: "model_not_found",
                style: .openAI,
                headers: cors
            )
        }
        return jsonResponse(
            OpenAI.Model(id: model.id, created: Int(Date().timeIntervalSince1970), owned_by: "pocketd"),
            headers: cors
        )
    }

    func handleChatCompletions(_ request: HTTPRequest) async -> HTTPResponse {
        let cors = corsHeaders()
        if let rejection = authorize(request) { return rejection }

        let payload: OpenAI.ChatCompletionRequest
        do {
            payload = try JSONDecoder().decode(OpenAI.ChatCompletionRequest.self, from: await request.bodyData)
        } catch {
            return errorResponse(status: .badRequest, message: "Malformed request body: \(error)", style: .openAI, headers: cors)
        }

        let wantsStream = payload.stream ?? false
        let logID = await beginLog(request, streamed: wantsStream)

        guard beginRequest() else {
            await finishLog(logID, status: 503)
            var headers = cors
            headers[HTTPHeader("Retry-After")] = "2"
            return errorResponse(
                status: .serviceUnavailable,
                message: "The device is already generating. Retry shortly.",
                type: "server_busy",
                style: .openAI,
                headers: headers
            )
        }

        let model: ModelRecord
        do {
            model = try await resolveModel(id: payload.model)
        } catch {
            endRequest()
            await finishLog(logID, status: 404)
            return response(for: error, style: .openAI, headers: cors)
        }

        var options = payload.generationOptions()
        options.maxTokens = min(options.maxTokens ?? contextCap(), contextCap())
        let generation = GenerationRequest(modelID: model.id, messages: payload.chatMessages(), options: options)

        return wantsStream
            ? await streamChatCompletion(
                generation, model: model, logID: logID, cors: cors,
                includeUsage: payload.stream_options?.include_usage ?? false
              )
            : await bufferedChatCompletion(generation, model: model, logID: logID, cors: cors)
    }

    private func bufferedChatCompletion(
        _ generation: GenerationRequest,
        model: ModelRecord,
        logID: UUID,
        cors: HTTPHeaders
    ) async -> HTTPResponse {
        let started = ContinuousClock.now
        defer { endRequest() }
        do {
            let result = try await currentEngine().complete(generation)
            await finishLog(logID, status: 200, model: model.id, usage: result.usage, started: started)
            return jsonResponse(
                OpenAI.ChatCompletionResponse(
                    id: "chatcmpl-\(UUID().uuidString.prefix(24))",
                    created: Int(Date().timeIntervalSince1970),
                    model: model.id,
                    choices: [OpenAI.ChatChoice(
                        index: 0,
                        message: OpenAI.Message(role: "assistant", content: result.text),
                        finish_reason: result.reason.rawValue
                    )],
                    usage: OpenAI.Usage(result.usage),
                    system_fingerprint: PocketdKit.systemFingerprint
                ),
                headers: cors
            )
        } catch {
            await finishLog(logID, status: 500, model: model.id, started: started)
            return response(for: error, style: .openAI, headers: cors)
        }
    }

    private func streamChatCompletion(
        _ generation: GenerationRequest,
        model: ModelRecord,
        logID: UUID,
        cors: HTTPHeaders,
        includeUsage: Bool
    ) async -> HTTPResponse {
        let engine = currentEngine()
        let log = self.log
        var headers = ServerSentEvents.headers
        for (key, value) in cors { headers[key] = value }
        let completionID = "chatcmpl-\(UUID().uuidString.prefix(24))"
        let created = Int(Date().timeIntervalSince1970)

        return HTTPResponse.streaming(headers: headers) { [weak self] continuation in
            Task {
                let started = ContinuousClock.now
                let encoder = JSONEncoder()
                var usage = TokenUsage()
                var status = 200

                func chunk(delta: OpenAI.Delta, finish: String? = nil) -> OpenAI.ChatCompletionChunk {
                    OpenAI.ChatCompletionChunk(
                        id: completionID,
                        created: created,
                        model: model.modelIDForWire,
                        choices: [OpenAI.ChunkChoice(index: 0, delta: delta, finish_reason: finish)],
                        system_fingerprint: PocketdKit.systemFingerprint
                    )
                }

                do {
                    // The first chunk carries the role and no content, which is
                    // what the OpenAI SDKs use to open the assistant message.
                    if let frame = try? ServerSentEvents.frame(json: chunk(delta: OpenAI.Delta(role: "assistant")), encoder: encoder) {
                        continuation.yield(frame)
                    }
                    for try await event in try await engine.generate(generation) {
                        switch event {
                        case .token(let text):
                            if let frame = try? ServerSentEvents.frame(json: chunk(delta: OpenAI.Delta(content: text)), encoder: encoder) {
                                continuation.yield(frame)
                            }
                        case .finished(let reason, let tokenUsage):
                            usage = tokenUsage
                            if let frame = try? ServerSentEvents.frame(json: chunk(delta: OpenAI.Delta(), finish: reason.rawValue), encoder: encoder) {
                                continuation.yield(frame)
                            }
                        }
                    }
                    // Per the OpenAI streaming spec the usage chunk carries an
                    // empty `choices` array, and it comes after the chunk that
                    // reported the finish reason.
                    if includeUsage {
                        let final = OpenAI.ChatCompletionChunk(
                            id: completionID,
                            created: created,
                            model: model.modelIDForWire,
                            choices: [],
                            usage: OpenAI.Usage(usage),
                            system_fingerprint: PocketdKit.systemFingerprint
                        )
                        if let frame = try? ServerSentEvents.frame(json: final, encoder: encoder) {
                            continuation.yield(frame)
                        }
                    }
                    continuation.yield(ServerSentEvents.done)
                } catch {
                    // The status line is long gone by the time a mid-stream
                    // failure happens, so the only honest signal left is an
                    // error event in the stream itself.
                    status = 500
                    let body = OpenAI.ErrorResponse(error: OpenAI.ErrorBody(
                        message: String(describing: error), type: "server_error", code: nil
                    ))
                    if let frame = try? ServerSentEvents.frame(json: body, encoder: encoder) {
                        continuation.yield(frame)
                    }
                    continuation.yield(ServerSentEvents.done)
                }

                continuation.finish()
                await self?.endRequest()
                let elapsed = started.duration(to: .now).timeInterval
                let finalStatus = status
                let finalUsage = usage
                await log.update(id: logID) { entry in
                    entry.statusCode = finalStatus
                    entry.model = model.id
                    entry.promptTokens = finalUsage.promptTokens
                    entry.completionTokens = finalUsage.completionTokens
                    entry.duration = elapsed
                }
            }
        }
    }

    func handleCompletions(_ request: HTTPRequest) async -> HTTPResponse {
        let cors = corsHeaders()
        if let rejection = authorize(request) { return rejection }

        let payload: OpenAI.CompletionRequest
        do {
            payload = try JSONDecoder().decode(OpenAI.CompletionRequest.self, from: await request.bodyData)
        } catch {
            return errorResponse(status: .badRequest, message: "Malformed request body: \(error)", style: .openAI, headers: cors)
        }

        // The legacy completions endpoint is served by lifting the prompt into a
        // single user turn. Chat-tuned models are the only kind that fit on a
        // phone, so there is no raw-completion path worth keeping separate.
        let chat = OpenAI.ChatCompletionRequest(
            model: payload.model,
            messages: [OpenAI.Message(role: "user", content: payload.prompt)],
            stream: payload.stream,
            temperature: payload.temperature,
            top_p: payload.top_p,
            max_tokens: payload.max_tokens,
            stop: payload.stop,
            seed: payload.seed
        )
        guard let body = try? JSONEncoder().encode(chat) else {
            return errorResponse(status: .internalServerError, message: "Failed to adapt request.", style: .openAI, headers: cors)
        }
        var forwarded = request
        forwarded.bodySequence = HTTPBodySequence(data: body)
        return await handleChatCompletions(forwarded)
    }
}

private extension ModelRecord {
    /// Clients echo this back in their UI, so it is the id, never the pretty name.
    var modelIDForWire: String { id }
}
