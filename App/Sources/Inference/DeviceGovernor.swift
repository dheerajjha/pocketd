import Foundation
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

    init(batteryFloor: Double, onChange: @escaping (ServeCondition) -> Void) {
        self.batteryFloor = batteryFloor
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

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    private func evaluate() {
        let thermal = ProcessInfo.processInfo.thermalState
        let next = ServeCondition.evaluate(
            thermalIsSevere: thermal == .serious || thermal == .critical,
            thermalIsElevated: thermal == .fair,
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
