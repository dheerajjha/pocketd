import Foundation
import FlyingFox

extension InferenceServer {
    func handleOllamaTags(_ request: HTTPRequest) async -> HTTPResponse {
        let cors = corsHeaders()
        if let rejection = authorize(request) { return rejection }
        let resident = await currentEngine().loadedModel()
        return jsonResponse(
            Ollama.TagsResponse(models: await models().map { model in
                Ollama.tagEntry(for: model, capabilities: capabilities(for: model, resident: resident))
            }),
            headers: cors
        )
    }

    func handleOllamaShow(_ request: HTTPRequest) async -> HTTPResponse {
        let cors = corsHeaders()
        if let rejection = authorize(request) { return rejection }
        let payload = (try? JSONDecoder().decode(Ollama.ShowRequest.self, from: await request.bodyData))
            ?? Ollama.ShowRequest(name: nil, model: nil)
        guard let model = await models().first(where: { $0.id == payload.resolved }) else {
            return errorResponse(status: .notFound, message: "model '\(payload.resolved)' not found", style: .ollama, headers: cors)
        }
        return jsonResponse(
            Ollama.ShowResponse(
                license: model.license,
                details: Ollama.details(for: model),
                model_info: ["general.context_length": min(model.contextLength, contextCap())]
            ),
            headers: cors
        )
    }

    func handleOllamaPs(_ request: HTTPRequest) async -> HTTPResponse {
        let cors = corsHeaders()
        if let rejection = authorize(request) { return rejection }
        guard let model = await currentEngine().loadedModel() else {
            return jsonResponse(Ollama.ProcessResponse(models: []), headers: cors)
        }
        return jsonResponse(
            Ollama.ProcessResponse(models: [
                Ollama.ProcessEntry(
                    name: model.id,
                    model: model.id,
                    size: model.estimatedResidentBytes,
                    digest: Ollama.tagEntry(for: model).digest,
                    details: Ollama.details(for: model),
                    // The model stays resident until it is replaced or the app
                    // is killed; there is no idle eviction timer to report.
                    expires_at: Ollama.timestamp(Date(timeIntervalSince1970: 0)),
                    // Unified memory: there is no separate VRAM figure to give.
                    size_vram: model.estimatedResidentBytes,
                    context_length: min(model.contextLength, contextCap())
                )
            ]),
            headers: cors
        )
    }

    func handleOllamaChat(_ request: HTTPRequest) async -> HTTPResponse {
        let cors = corsHeaders()
        if let rejection = authorize(request) { return rejection }

        let payload: Ollama.ChatRequest
        do {
            payload = try JSONDecoder().decode(Ollama.ChatRequest.self, from: await request.bodyData)
        } catch {
            return errorResponse(status: .badRequest, message: "invalid request: \(error)", style: .ollama, headers: cors)
        }

        let messages = payload.messages.map {
            ChatMessage(
                role: ChatMessage.Role(rawValue: $0.role) ?? .user,
                content: $0.content,
                images: $0.imageData
            )
        }
        // Ollama streams unless told otherwise — the opposite of OpenAI's default.
        return await runOllama(
            request: request,
            modelID: payload.model,
            messages: messages,
            options: payload.options?.generationOptions() ?? .default,
            stream: payload.stream ?? true,
            shape: .chat,
            cors: cors
        )
    }

    func handleOllamaGenerate(_ request: HTTPRequest) async -> HTTPResponse {
        let cors = corsHeaders()
        if let rejection = authorize(request) { return rejection }

        let payload: Ollama.GenerateRequest
        do {
            payload = try JSONDecoder().decode(Ollama.GenerateRequest.self, from: await request.bodyData)
        } catch {
            return errorResponse(status: .badRequest, message: "invalid request: \(error)", style: .ollama, headers: cors)
        }

        var messages: [ChatMessage] = []
        if let system = payload.system, !system.isEmpty { messages.append(.system(system)) }
        messages.append(.user(payload.prompt))

        return await runOllama(
            request: request,
            modelID: payload.model,
            messages: messages,
            options: payload.options?.generationOptions() ?? .default,
            stream: payload.stream ?? true,
            shape: .generate,
            cors: cors
        )
    }

    enum OllamaShape {
        case chat
        case generate
    }

    private func runOllama(
        request: HTTPRequest,
        modelID: String,
        messages: [ChatMessage],
        options: GenerationOptions,
        stream: Bool,
        shape: OllamaShape,
        cors: HTTPHeaders
    ) async -> HTTPResponse {
        let logID = await beginLog(request, streamed: stream)

        guard beginRequest() else {
            await finishLog(logID, status: 503)
            var headers = cors
            headers[HTTPHeader("Retry-After")] = "2"
            return errorResponse(status: .serviceUnavailable, message: "device busy", style: .ollama, headers: headers)
        }

        let model: ModelRecord
        do {
            model = try await resolveModel(id: modelID)
        } catch {
            endRequest()
            await finishLog(logID, status: 404)
            return response(for: error, style: .ollama, headers: cors)
        }

        do {
            try ContextGuard(contextTokens: contextCap()).check(messages)
        } catch {
            endRequest()
            await finishLog(logID, status: 413, model: model.id)
            return response(for: error, style: .ollama, headers: cors)
        }

        var capped = options
        capped.maxTokens = min(capped.maxTokens ?? contextCap(), contextCap())
        let generation = GenerationRequest(modelID: model.id, messages: messages, options: capped)

        guard stream else {
            let started = ContinuousClock.now
            defer { endRequest() }
            do {
                let result = try await currentEngine().complete(generation)
                let elapsed = started.duration(to: .now).timeInterval
                await finishLog(logID, status: 200, model: model.id, usage: result.usage, started: started)
                return jsonResponse(
                    ollamaBody(shape: shape, model: model.id, text: result.text, done: true,
                               reason: result.reason.rawValue, usage: result.usage, elapsed: elapsed),
                    headers: cors
                )
            } catch {
                await finishLog(logID, status: 500, model: model.id, started: started)
                return response(for: error, style: .ollama, headers: cors)
            }
        }

        let engine = currentEngine()
        let log = self.log
        var headers = cors
        // Ollama streams newline-delimited JSON, not SSE. A client fed `data: `
        // prefixes here parses nothing at all.
        headers[.contentType] = "application/x-ndjson"
        headers[.cacheControl] = "no-cache"

        return HTTPResponse.streaming(headers: headers) { [weak self] continuation in
            Task {
                let started = ContinuousClock.now
                let encoder = JSONEncoder()
                var usage = TokenUsage()
                var status = 200

                func emit(_ value: some Encodable) {
                    guard var data = try? encoder.encode(value) else { return }
                    data.append(0x0A)
                    continuation.yield(data)
                }

                do {
                    for try await event in try await engine.generate(generation) {
                        switch event {
                        case .token(let text):
                            emit(ollamaBody(shape: shape, model: model.id, text: text, done: false,
                                            reason: nil, usage: nil, elapsed: nil))
                        case .finished(let reason, let tokenUsage):
                            usage = tokenUsage
                            emit(ollamaBody(shape: shape, model: model.id, text: "", done: true,
                                            reason: reason.rawValue, usage: tokenUsage,
                                            elapsed: started.duration(to: .now).timeInterval))
                        }
                    }
                } catch {
                    status = 500
                    emit(Ollama.ErrorResponse(error: String(describing: error)))
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
}

/// Builds whichever of the two near-identical Ollama response shapes the caller
/// asked for. They differ only in whether the text sits under `message.content`
/// or `response`, but clients are strict about which one they get.
private func ollamaBody(
    shape: InferenceServer.OllamaShape,
    model: String,
    text: String,
    done: Bool,
    reason: String?,
    usage: TokenUsage?,
    elapsed: TimeInterval?
) -> any Encodable & Sendable {
    let nanoseconds = elapsed.map { Int64($0 * 1_000_000_000) }
    switch shape {
    case .chat:
        return Ollama.ChatResponse(
            model: model,
            created_at: Ollama.timestamp(),
            message: Ollama.Message(role: "assistant", content: text),
            done: done,
            done_reason: done ? reason : nil,
            total_duration: nanoseconds,
            load_duration: 0,
            prompt_eval_count: usage?.promptTokens,
            prompt_eval_duration: nanoseconds,
            eval_count: usage?.completionTokens,
            eval_duration: nanoseconds
        )
    case .generate:
        return Ollama.GenerateResponse(
            model: model,
            created_at: Ollama.timestamp(),
            response: text,
            done: done,
            done_reason: done ? reason : nil,
            total_duration: nanoseconds,
            load_duration: 0,
            prompt_eval_count: usage?.promptTokens,
            prompt_eval_duration: nanoseconds,
            eval_count: usage?.completionTokens,
            eval_duration: nanoseconds
        )
    }
}
