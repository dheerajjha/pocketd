import Foundation

/// A ready-to-paste configuration for one client.
///
/// The point is that nobody should ever retype a base URL or a 35-character key
/// off a phone screen. These are rendered into the setup page the phone serves,
/// so the pasting happens on the laptop, where pasting is free.
public struct ClientSnippet: Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    /// Syntax class for the setup page, e.g. `"yaml"`, `"python"`.
    public let language: String
    public let body: String
    /// Set when the snippet is a whole file the user should download.
    public let filename: String?
    /// The caveat that would otherwise cost someone an afternoon.
    public let note: String?

    public init(
        id: String,
        title: String,
        language: String,
        body: String,
        filename: String? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.title = title
        self.language = language
        self.body = body
        self.filename = filename
        self.note = note
    }
}

public enum ClientSnippets {
    /// Every snippet for a running server. `apiKey` nil means auth is off.
    ///
    /// The OpenAI dialect lives under `/v1` and the Ollama dialect at the root;
    /// getting that wrong is the single most common reason a client cannot see
    /// the server, so it is encoded here rather than left to the reader.
    public static func all(baseURL: URL, apiKey: String?, model: String) -> [ClientSnippet] {
        let base = baseURL.absoluteString
        let v1 = base + "/v1"
        // The OpenAI SDKs reject an empty api_key outright, so an
        // auth-disabled server still needs a placeholder rather than "".
        let sdkKey = apiKey ?? "not-needed"
        let curlAuth = apiKey.map { "\n  -H \"Authorization: Bearer \($0)\" \\" } ?? ""
        let noAuthNote = apiKey == nil
            ? "Auth is off on this server, but the OpenAI SDKs refuse an empty key — any placeholder works."
            : nil

        return [
            ClientSnippet(
                id: "curl",
                title: "curl",
                language: "bash",
                body: """
                curl \(v1)/chat/completions \\
                  -H "Content-Type: application/json" \\\(curlAuth)
                  -d '{"model":"\(model)","messages":[{"role":"user","content":"hello"}]}'
                """,
                note: noAuthNote
            ),
            ClientSnippet(
                id: "continue",
                title: "Continue",
                language: "yaml",
                body: """
                models:
                  - name: \(model)
                    provider: openai
                    model: \(model)
                    apiBase: \(v1)
                    apiKey: \(sdkKey)
                """,
                filename: "config.yaml",
                note: "Paste into ~/.continue/config.yaml under models:."
            ),
            ClientSnippet(
                id: "openai-python",
                title: "Python",
                language: "python",
                body: """
                from openai import OpenAI

                client = OpenAI(base_url="\(v1)", api_key="\(sdkKey)")

                stream = client.chat.completions.create(
                    model="\(model)",
                    messages=[{"role": "user", "content": "hello"}],
                    stream=True,
                )
                for chunk in stream:
                    print(chunk.choices[0].delta.content or "", end="")
                """,
                note: noAuthNote
            ),
            ClientSnippet(
                id: "openai-js",
                title: "JavaScript",
                language: "javascript",
                body: """
                import OpenAI from "openai";

                const client = new OpenAI({
                  baseURL: "\(v1)",
                  apiKey: "\(sdkKey)",
                });

                const stream = await client.chat.completions.create({
                  model: "\(model)",
                  messages: [{ role: "user", content: "hello" }],
                  stream: true,
                });
                for await (const chunk of stream) {
                  process.stdout.write(chunk.choices[0]?.delta?.content ?? "");
                }
                """,
                note: noAuthNote
            ),
            ClientSnippet(
                id: "open-webui",
                title: "Open WebUI",
                language: "text",
                body: """
                Settings → Connections → Ollama

                  URL:     \(base)
                  API key: \(apiKey ?? "(leave blank)")
                """,
                note: "Open WebUI in Docker cannot reach your phone on the host network. Run it with --network host, or add --add-host and use your phone's address."
            ),
            ClientSnippet(
                id: "aider",
                title: "Aider",
                language: "bash",
                body: """
                export OPENAI_API_BASE=\(v1)
                export OPENAI_API_KEY=\(sdkKey)

                aider --model openai/\(model)
                """,
                note: noAuthNote
            ),
        ]
    }
}
