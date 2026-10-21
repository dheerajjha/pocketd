import Foundation

/// How one request in the log is said on the phone.
///
/// The log is the one place someone can check what another device has been
/// asking this phone for, so it has to be readable by whoever owns the phone —
/// not only by whoever wrote the client. "POST /api/chat · 503" is the wire's
/// account of it; "Question · Busy" is the same fact for the person holding
/// the phone. The raw path and status stay on the entry for anything that
/// wants them.
public extension RequestLogEntry {
    /// What the other device asked for, in a word or two.
    var requestKind: String {
        switch path {
        case "/v1/chat/completions", "/v1/completions", "/api/chat", "/api/generate":
            "Question"
        case "/pair":
            "Pairing"
        case "/", "/chat", "/setup":
            "Chat page"
        case "/health", "/api/version":
            "Status check"
        case "/api/pull", "/api/models/add":
            "Brain download"
        case "/api/search", "/api/search/files":
            "Brain search"
        case _ where path.hasPrefix("/v1/models") || ["/api/tags", "/api/ps", "/api/show", "/api/catalogue"].contains(path):
            "Brain list"
        case "/v1/embeddings", "/api/embed", "/api/embeddings":
            "Unsupported request"
        default:
            "Other request"
        }
    }

    /// How it went, in a word or two. `nil` while a reply is still streaming.
    var outcome: String? {
        switch statusCode {
        case 0: nil
        case 200..<300: path == "/pair" ? "Paired" : "Answered"
        case 400: "Not understood"
        case 401: "Wrong key"
        case 403: path == "/pair" ? "Wrong code" : "Refused"
        case 404: "Not found"
        case 413: "Too long"
        case InferenceServer.clientClosedRequest: "Stopped early"
        case 501: "Not supported"
        case 503: "Busy or paused"
        default: "Failed"
        }
    }

    /// Whether the outcome is worth drawing the eye to: a refusal or a
    /// failure, as opposed to an answer, a reply still on its way, or a
    /// device that simply stopped listening.
    var outcomeIsTrouble: Bool {
        statusCode >= 400 && statusCode != InferenceServer.clientClosedRequest
    }
}
