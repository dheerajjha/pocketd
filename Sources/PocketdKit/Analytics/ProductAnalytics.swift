import Foundation

public enum AnalyticsPlan: String, Sendable, CaseIterable {
    case unknown, free, lifetime
    case earlySupporter = "early_supporter"

    public var isPro: Bool? {
        switch self {
        case .unknown: nil
        case .free: false
        case .lifetime, .earlySupporter: true
        }
    }
}

public enum AnalyticsAppearance: String, Sendable, CaseIterable { case unknown, light, dark }
public enum AnalyticsTypeSize: String, Sendable, CaseIterable { case unknown, standard, large, accessibility }
public enum AnalyticsNotificationStatus: String, Sendable, CaseIterable {
    case unknown, denied, authorized, provisional, ephemeral
    case notDetermined = "not_determined"
}
public enum AnalyticsInstallAge: String, Sendable, CaseIterable {
    case day0 = "day_0"
    case days1To6 = "days_1_6"
    case days7To29 = "days_7_29"
    case days30To89 = "days_30_89"
    case days90Plus = "days_90_plus"
}
public enum AnalyticsFeature: String, Sendable, CaseIterable {
    case deskMode = "desk_mode"
    case intentAsk = "intent_ask"
    case controlAsk = "control_ask"
    case routineNotification = "routine_notification"
    case deepLink = "deep_link"
}
public enum AnalyticsSurface: String, Sendable, CaseIterable { case app, intent, control, notification, link }
public enum AnalyticsPaywallTrigger: String, Sendable, CaseIterable { case pro, laptop, routines, brains }
public enum AnalyticsRestoreOutcome: String, Sendable, CaseIterable { case restored, empty, cancelled, failed }
public enum AnalyticsPermission: String, Sendable, CaseIterable { case calendar, reminders, health, notifications }
public enum AnalyticsPermissionOutcome: String, Sendable, CaseIterable {
    case granted, denied, blocked, unavailable, failed
    /// HealthKit reports that the request completed, not whether reads were granted.
    case completed
}
public enum AnalyticsSetting: String, Sendable, CaseIterable {
    case authentication, reasoning
    case keepAwake = "keep_awake"
}
public enum AnalyticsShare: String, Sendable, CaseIterable { case address, diagnostics }
public enum AnalyticsErrorArea: String, Sendable, CaseIterable { case server, chat, purchase, restore }
public enum AnalyticsScreen: String, Sendable, CaseIterable {
    case onboarding, today, ask, routines, you, day, reminders, sleep, activity, brain, devices, privacy, settings, instructions, diagnostics
    case routineResult = "routine_result"
    case addBrain = "add_brain"
    case brainAdvanced = "brain_advanced"
    case deskMode = "desk_mode"
    case privacyDetails = "privacy_details"
}

/// A newer verified result wins; a scan started before a purchase must not republish old ownership.
@MainActor
public final class AnalyticsPlanPublication {
    private var revision = 0
    private let publish: @MainActor (AnalyticsPlan) -> Void
    public init(publish: @escaping @MainActor (AnalyticsPlan) -> Void) { self.publish = publish }
    @discardableResult public func invalidate() -> Int {
        revision += 1
        publish(.unknown)
        return revision
    }
    public func accept(_ plan: AnalyticsPlan, revision expected: Int? = nil) {
        guard expected == nil || expected == revision else { return }
        publish(plan)
    }
}

/// Event context is mapped through the same allow-list as the event itself.
/// Unknown ownership omits is_pro rather than reporting a cached gate as verified.
public struct AnalyticsContext: Sendable, Equatable {
    public var plan: AnalyticsPlan = .unknown
    public var appearance: AnalyticsAppearance = .unknown
    public var typeSize: AnalyticsTypeSize = .unknown
    public var notifications: AnalyticsNotificationStatus = .unknown
    public var installAge: AnalyticsInstallAge = .day0
    public init() {}

    public var properties: [String: AnalyticsValue] {
        var result: [String: AnalyticsValue] = [
            "plan": .string(plan.rawValue), "appearance": .string(appearance.rawValue),
            "dynamic_type": .string(typeSize.rawValue), "notification_status": .string(notifications.rawValue),
            "install_age_days": .string(installAge.rawValue)
        ]
        if let isPro = plan.isPro { result["is_pro"] = .bool(isPro) }
        if notifications != .unknown {
            result["notifications_authorised"] = .bool([.authorized, .provisional, .ephemeral].contains(notifications))
        }
        return result
    }
}

/// The runtime path shared by AppModel's actions and server-log observer.
/// Only analytics timestamps/latches persist; request identifiers stay in memory.
@MainActor
public final class ProductAnalytics {
    public static let installKey = "pocketd.analytics.installDate"
    public static let firstValueKey = "pocketd.analytics.firstValueReached"
    private let defaults: UserDefaults
    private let sink: any AnalyticsSink
    private let installDate: Date
    public var context = AnalyticsContext()
    private var handledRequests = Set<UUID>()
    private var requestsAfter = Date.distantPast

    public init(sink: any AnalyticsSink, defaults: UserDefaults = .standard, now: Date = Date()) {
        self.sink = sink
        self.defaults = defaults
        if let date = defaults.object(forKey: Self.installKey) as? Date {
            installDate = date
        } else {
            installDate = now
            defaults.set(now, forKey: Self.installKey)
        }
    }

    public func record(_ event: AnalyticsEvent, consent: AnalyticsConsent, now: Date = Date()) {
        guard consent.permitsSending, !(sink is NoAnalytics) else { return }
        let days = max(0, Int(now.timeIntervalSince(installDate) / 86_400))
        context.installAge = switch days {
        case 0: .day0
        case 1...6: .days1To6
        case 7...29: .days7To29
        case 30...89: .days30To89
        default: .days90Plus
        }
        sink.record(event, context: context)
    }

    public func firstValue(consent: AnalyticsConsent, now: Date = Date()) {
        guard consent.permitsSending, !(sink is NoAnalytics), !defaults.bool(forKey: Self.firstValueKey) else { return }
        // Write before sending: SDK reset/opt-out must never reset this install's latch.
        defaults.set(true, forKey: Self.firstValueKey)
        record(.firstValueReached(secondsSinceInstall: max(0, now.timeIntervalSince(installDate))), consent: consent, now: now)
    }

    /// A request started while opted out may finish after opt-in. Never replay it.
    public func consentChanged(now: Date = Date()) { requestsAfter = now }

    public func observeRequests(_ entries: [RequestLogEntry], consent: AnalyticsConsent, now: Date = Date()) {
        let current = Set(entries.map(\.id))
        handledRequests.formIntersection(current)
        for entry in entries.reversed() where entry.statusCode != 0 && !handledRequests.contains(entry.id) {
            handledRequests.insert(entry.id)
            guard entry.date >= requestsAfter else { continue }
            guard entry.generationCompleted, (200..<300).contains(entry.statusCode),
                  let dialect = AnalyticsMapping.dialect(path: entry.path) else { continue }
            if AnalyticsMapping.isExternal(clientAddress: entry.clientAddress) {
                record(.externalClientConnected(dialect: dialect), consent: consent, now: now)
                firstValue(consent: consent, now: now)
            } else if entry.clientAddress != nil {
                record(.onDeviceClientConnected(dialect: dialect), consent: consent, now: now)
            }
        }
    }
}
