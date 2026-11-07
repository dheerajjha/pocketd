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
        let curlAuth = apiKey.map { "\n  -H \"Authorization: Bearer \($0)\" \\" } ?? ""
        let httpAuth = apiKey.map { ", \"Authorization\": \"Bearer \($0)\"" } ?? ""

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
                note: nil
            ),
            ClientSnippet(
                id: "python",
                title: "Python",
                language: "python",
                body: """
                import json
                from urllib.request import Request, urlopen

                request = Request(
                    "\(v1)/chat/completions",
                    data=json.dumps({
                        "model": "\(model)",
                        "messages": [{"role": "user", "content": "hello"}],
                        "stream": False,
                        "max_tokens": 64,
                    }).encode(),
                    headers={"Content-Type": "application/json"\(httpAuth)},
                )
                with urlopen(request, timeout=120) as response:
                    result = json.load(response)
                print(result["choices"][0]["message"]["content"])
                """,
                note: "Uses Python's standard library; no package to install."
            ),
            ClientSnippet(
                id: "javascript",
                title: "JavaScript",
                language: "javascript",
                body: """
                const response = await fetch("\(v1)/chat/completions", {
                  method: "POST",
                  headers: {"Content-Type": "application/json"\(httpAuth)},
                  body: JSON.stringify({
                    model: "\(model)",
                    messages: [{role: "user", content: "hello"}],
                    stream: false,
                    max_tokens: 64,
                  }),
                });
                const result = await response.json();
                if (!response.ok) {
                  throw new Error(result.error?.message ?? "Request failed");
                }
                console.log(result.choices[0].message.content);
                """,
                note: "Uses built-in fetch; no SDK to install."
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
        ]
    }
}
