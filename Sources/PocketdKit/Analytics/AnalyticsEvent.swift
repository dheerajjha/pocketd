import Foundation

/// A value that may be sent off the device.
///
/// Deliberately not `Any`. The whole safety argument for shipping telemetry
/// from an app that promises nothing leaves the phone rests on being able to
/// enumerate, in a test, every value that can be transmitted — and `Any` makes
/// that impossible to check.
public enum AnalyticsValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
}

// MARK: - Bounded reasons

/// Why a download ended badly.
///
/// A closed set, and that is the point rather than tidiness. The natural
/// source for a reason string here is `LocalizedError.errorDescription` or the
/// message inside `ModelTransfer.State.failed`, and sending either would ship
/// unbounded text off the device. This codebase has already made that mistake
/// once in the other direction: a `URLError`'s `userInfo` carries the signed
/// CDN URL and the whole resume blob, and `String(describing:)` put all of it
/// on screen. Mapping to cases means the worst case is `.unknown`.
public enum DownloadFailureReason: String, Sendable, CaseIterable {
    case offline            = "offline"
    case timedOut           = "timed_out"
    case httpError          = "http_error"
    case insufficientDisk   = "insufficient_disk"
    case insufficientMemory = "insufficient_memory"
    case incompleteBytes    = "incomplete_bytes"
    /// Deliberately not the error's own text. See the note above.
    case other              = "other"
}

/// Why a model that was on disk would not load.
///
/// The most valuable thing in the whole taxonomy: this is the on-device risk
/// the app shipped without ever measuring across more than one handset.
public enum LoadFailureReason: String, Sendable, CaseIterable {
    case outOfMemory       = "out_of_memory"
    case unsupportedFormat = "unsupported_format"
    case missingProjector  = "missing_projector"
    case fileMissing       = "file_missing"
    case other             = "other"
}

/// Why the server declined to generate.
public enum RefusalReason: String, Sendable, CaseIterable {
    case thermal
    case battery
    case concurrent
}

/// Which API surface a client spoke.
///
/// Derived from the request path — `/v1/*` against `/api/*` — not from
/// anything the client asserted about itself.
public enum ClientDialect: String, Sendable, CaseIterable {
    case openai
    case ollama
}

/// How someone left the intro.
///
/// Split because `OnboardingView.leave(to:)` is called by Skip and by the
/// destination cards alike, so a single "completed" event cannot distinguish
/// the person who read it from the person who dismissed it — and that
/// distinction is most of what the cold-start funnel is asking.
public enum OnboardingExit: String, Sendable, CaseIterable {
    case finished
    case skipped
}

public enum OnboardingDestination: String, Sendable, CaseIterable {
    case chat
    case server
    case models
}

// MARK: - The events

/// Everything this app may report about itself.
///
/// An enum rather than free-form `track(name:properties:)` calls, so that the
/// complete set of transmittable facts is one readable list that a reviewer —
/// or a suspicious user reading the source, which this app's audience actually
/// does — can check in a minute.
public enum AnalyticsEvent: Sendable, Equatable {
    case appOpened(isFirstLaunch: Bool)
    case onboardingCompleted(via: OnboardingExit, destination: OnboardingDestination)

    case modelDownloadStarted(modelID: String, sizeBytes: Int64)
    case modelDownloadCompleted(modelID: String, durationSeconds: Double)
    case modelDownloadCancelled(modelID: String, percentComplete: Int)
    case modelDownloadFailed(modelID: String, reason: DownloadFailureReason)
    case oversizeOverride(modelID: String)

    /// No device_model property: the SDK already attaches $ios_device_model
    /// to every event, and two properties carrying the same fact in a schema
    /// this young is drift on day one. ram_class stays because it is a derived
    /// bucket the SDK does not provide, and it is the axis the memory question
    /// is actually asked along.
    case modelLoadSucceeded(modelID: String, ramClass: String, loadMilliseconds: Int)
    case modelLoadFailed(modelID: String, ramClass: String, reason: LoadFailureReason)

    case chatMessageSent(modelID: String)
    case serverStarted
    /// How long it actually served, which is not how long the app was open.
    ///
    /// The listener dies when the app backgrounds, so foreground time and
    /// serving time are different numbers and only one of them is the product.
    /// Mixpanel's automatic session tracking measures the wrong one, which is
    /// why it is off — but declining it left nothing measuring the right one.
    case serverStopped(servedSeconds: Double)
    /// The moment this stops being a chat app and starts being the product.
    ///
    /// Emitted for LAN clients only. The phone's own /chat page is a network
    /// client at the route layer — deliberately, since privileging it would be
    /// a security hole — so counting loopback would inflate the one number
    /// this event exists to report. A boolean property would keep the data
    /// honest and still let a reader who forgets the caveat quote the headline
    /// wrong, and the headline is what gets quoted. The event means what its
    /// name says instead.
    case externalClientConnected(dialect: ClientDialect)
    /// The phone answering its own served chat page.
    ///
    /// Kept out of `externalClientConnected` so that number means what its
    /// name says — but kept, rather than discarded. Excluding loopback from
    /// the north-star metric and throwing the data away were presented as one
    /// decision and are two; this is the second one going the other way.
    case onDeviceClientConnected(dialect: ClientDialect)
    case generationRefused(reason: RefusalReason)

    public var name: String {
        switch self {
        case .appOpened: "app_opened"
        case .onboardingCompleted: "onboarding_completed"
        case .modelDownloadStarted: "model_download_started"
        case .modelDownloadCompleted: "model_download_completed"
        case .modelDownloadCancelled: "model_download_cancelled"
        case .modelDownloadFailed: "model_download_failed"
        case .oversizeOverride: "oversize_override"
        case .modelLoadSucceeded: "model_load_succeeded"
        case .modelLoadFailed: "model_load_failed"
        case .chatMessageSent: "chat_message_sent"
        case .serverStarted: "server_started"
        case .serverStopped: "server_stopped"
        case .externalClientConnected: "external_client_connected"
        case .onDeviceClientConnected: "on_device_client_connected"
        case .generationRefused: "generation_refused"
        }
    }

    public var properties: [String: AnalyticsValue] {
        switch self {
        case let .appOpened(isFirstLaunch):
            ["is_first_launch": .bool(isFirstLaunch)]
        case let .onboardingCompleted(via, destination):
            ["via": .string(via.rawValue), "destination": .string(destination.rawValue)]
        case let .modelDownloadStarted(modelID, sizeBytes):
            ["model_id": .string(modelID), "size_bytes": .int(Int(sizeBytes))]
        case let .modelDownloadCompleted(modelID, duration):
            ["model_id": .string(modelID), "duration_s": .double(duration)]
        case let .modelDownloadCancelled(modelID, percent):
            ["model_id": .string(modelID), "percent_complete": .int(percent)]
        case let .modelDownloadFailed(modelID, reason):
            ["model_id": .string(modelID), "reason": .string(reason.rawValue)]
        case let .oversizeOverride(modelID):
            ["model_id": .string(modelID)]
        case let .modelLoadSucceeded(modelID, ram, loadMs):
            ["model_id": .string(modelID), "ram_class": .string(ram), "load_ms": .int(loadMs)]
        case let .modelLoadFailed(modelID, ram, reason):
            ["model_id": .string(modelID), "ram_class": .string(ram), "reason": .string(reason.rawValue)]
        case let .chatMessageSent(modelID):
            ["model_id": .string(modelID)]
        case .serverStarted:
            [:]
        case let .serverStopped(served):
            ["served_s": .double(served)]
        case let .externalClientConnected(dialect):
            ["dialect": .string(dialect.rawValue)]
        case let .onDeviceClientConnected(dialect):
            ["dialect": .string(dialect.rawValue)]
        case let .generationRefused(reason):
            ["reason": .string(reason.rawValue)]
        }
    }
}

// MARK: - The schema

/// The only property names any event may carry, by event name.
///
/// Written out by hand rather than derived from `properties`, because a schema
/// derived from the code it is checking cannot disagree with it. This repo has
/// shipped a test that asserted a source constant against itself and caught
/// nothing for weeks; the value of this table is precisely that it is a second,
/// independent statement of intent, and that changing one without the other is
/// a build failure.
public enum AnalyticsSchema {
    public static let allowedProperties: [String: Set<String>] = [
        "app_opened": ["is_first_launch"],
        "onboarding_completed": ["via", "destination"],
        "model_download_started": ["model_id", "size_bytes"],
        "model_download_completed": ["model_id", "duration_s"],
        "model_download_cancelled": ["model_id", "percent_complete"],
        "model_download_failed": ["model_id", "reason"],
        "oversize_override": ["model_id"],
        "model_load_succeeded": ["model_id", "ram_class", "load_ms"],
        "model_load_failed": ["model_id", "ram_class", "reason"],
        "chat_message_sent": ["model_id"],
        "server_started": [],
        "server_stopped": ["served_s"],
        "external_client_connected": ["dialect"],
        "on_device_client_connected": ["dialect"],
        "generation_refused": ["reason"]
    ]

    /// Property names that must never appear, whatever anyone adds later.
    ///
    /// The realistic failure is not malice, it is someone six months from now
    /// debugging a support ticket who adds `prompt` "just temporarily" to work
    /// out why a model refused a message. This list makes that a red test
    /// rather than a shipped regression, and it is the reason the banned names
    /// are broader than the things we currently have any way to send.
    public static let forbiddenProperties: Set<String> = [
        "prompt", "message", "text", "content", "completion", "response", "answer",
        "conversation", "transcript", "input", "output", "query",
        "address", "host", "ip", "ip_address", "hostname", "url", "endpoint",
        "filename", "file_name", "path", "file_path",
        "email", "name", "user_name", "username", "api_key", "key", "token",
        // Not personal, just duplicated: the SDK attaches $ios_device_model
        // to every event already, and a second copy is schema drift.
        "device_model",
        "steps", "heart_rate", "sleep", "workout", "calendar", "reminder", "event_title"
    ]
}
