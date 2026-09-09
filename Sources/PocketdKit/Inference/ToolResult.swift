import Foundation

/// How a tool's result is written into the prompt the model reads next.
///
/// This is the whole reason the engine does not use LocalLLMClient's own
/// `LLMSession.streamResponseWithAutomaticToolCalling`. That path formats a
/// result by iterating the output dictionary in whatever order the hash seed
/// produced, so the same tool returning the same data renders differently on
/// every launch — a different prompt, therefore different sampling, therefore
/// an answer nobody can reproduce or bisect. Sorted keys cost nothing and are
/// the shape the chat templates were trained on.
public enum ToolResult {

    /// Renders a tool's structured output as the model will read it.
    public static func encode(_ data: [String: any Sendable]) -> String {
        if JSONSerialization.isValidJSONObject(data),
           let encoded = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]) {
            return String(decoding: encoded, as: UTF8.self)
        }
        // A tool that returns something JSON cannot carry — a Date, a URL — must
        // still produce a result rather than an error, and that result has to be
        // as stable as the JSON one. Sorting by key is what makes it so.
        return data
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ")
    }

    /// What a call that could not run reports back instead of throwing.
    ///
    /// A failed tool must never break the stream. A 1–2B model hallucinates
    /// tool names and argument shapes as a matter of routine, and turning that
    /// into a thrown error hands the user a dead stream and a 500 for a
    /// question that only ever needed an answer. The model reads this, and
    /// either answers without the tool or says it could not check — both of
    /// which are outcomes; a 500 is not.
    ///
    /// Same JSON shape as a success so the template renders one kind of thing,
    /// and short because it is going into a context window measured in
    /// thousands of tokens.
    public static func failure(_ message: String) -> String {
        encode(["error": message])
    }

    /// The model asked for a tool that is not registered.
    public static func unknownTool(named name: String) -> String {
        failure("No tool named \"\(name)\" exists. Answer without it.")
    }

    /// The tool exists but could not run — undecodable arguments, or it threw.
    public static func failed(tool name: String) -> String {
        failure("\(name) could not run and returned nothing. Answer without it.")
    }
}
