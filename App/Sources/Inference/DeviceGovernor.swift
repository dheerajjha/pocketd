import Foundation

extension ThermalLevel {
    /// `ProcessInfo.ThermalState` is not `Comparable` and is not available to
    /// the package, so the mapping happens here, once.
    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .critical
        }
    }
}
import PocketdKit
#if canImport(UIKit)
import UIKit
#endif

/// Watches the two physical limits a phone has and a server does not.
///
/// `ServerConfiguration.pauseBelowBatteryLevel` existed from the first commit
/// and was read by nothing — the setting was in the UI, persisted, and inert.
/// This is what makes it mean something.
@MainActor
final class DeviceGovernor {
    private(set) var condition: ServeCondition = .ok
    private var observers: [NSObjectProtocol] = []
    private let onChange: (ServeCondition) -> Void
    private var batteryFloor: Double
    private var tolerance: ThermalTolerance

    init(
        batteryFloor: Double,
        tolerance: ThermalTolerance = .pausesWhenHot,
        onChange: @escaping (ServeCondition) -> Void
    ) {
        self.batteryFloor = batteryFloor
        self.tolerance = tolerance
        self.onChange = onChange
    }

    func start() {
        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            },
            center.addObserver(forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            },
            center.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            },
        ]
        evaluate()
        #endif
    }

    func updateBatteryFloor(_ floor: Double) {
        batteryFloor = floor
        evaluate()
    }

    /// Re-evaluates immediately, so a phone already paused for heat starts
    /// answering the moment the tolerance is widened rather than at the next
    /// thermal notification — which on a device that has settled may be a long
    /// time coming.
    func updateThermalTolerance(_ tolerance: ThermalTolerance) {
        self.tolerance = tolerance
        evaluate()
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    private func evaluate() {
        let thermal = ProcessInfo.processInfo.thermalState
        let next = ServeCondition.evaluate(
            thermal: ThermalLevel(thermal),
            tolerance: tolerance,
            batteryLevel: Self.currentBatteryLevel(),
            charging: Self.isCharging(),
            floor: batteryFloor,
            current: condition
        )
        guard next != condition else { return }
        condition = next
        onChange(next)
    }

    private static func currentBatteryLevel() -> Double {
        #if canImport(UIKit)
        Double(UIDevice.current.batteryLevel)   // -1 when unknown, handled by the caller
        #else
        -1
        #endif
    }

    private static func isCharging() -> Bool {
        #if canImport(UIKit)
        let state = UIDevice.current.batteryState
        return state == .charging || state == .full
        #else
        return true
        #endif
    }
}
