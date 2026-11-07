#if DEBUG
import Foundation
import PocketdKit

/// Opt-in local-notification diagnostics. No question or personal-data content
/// is recorded, and no code in this file is present in Release builds.
enum NotificationDiagnostics {
    private static let lock = NSLock()
    static var enabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-pocketd.notificationDiagnostics")
            || arguments.contains("-pocketd.notificationTest")
            || arguments.contains("-pocketd.notificationRawCallbacks")
    }

    static func record(_ event: String) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notification-check.log")
        let line = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
            + " pid=\(ProcessInfo.processInfo.processIdentifier) main=\(Thread.isMainThread) \(event)\n"
        guard let bytes = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? bytes.write(to: url)
        } else if let file = try? FileHandle(forWritingTo: url) {
            defer { try? file.close() }
            _ = try? file.seekToEnd()
            try? file.write(contentsOf: bytes)
        }
    }

    /// Creates one real, one-shot prompt routine through the normal store and
    /// notification arming path. Invoke with -pocketd.notificationTest warm|cold.
    @MainActor
    static func scheduleIfRequested(_ model: AppModel) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-pocketd.notificationTest"),
              arguments.indices.contains(index + 1),
              ["warm", "cold"].contains(arguments[index + 1]) else { return }
        let mode = arguments[index + 1]
        guard await NotificationCentre.shared.requestAuthorization() else {
            record("probe authorization unavailable")
            return
        }
        let id = UUID(uuidString: mode == "warm"
            ? "07CCAE3E-61D4-4B70-933A-F52797FD4C31"
            : "BD062DFD-7FC1-41E6-B7EC-B261B0E662D5")!
        let now = Date()
        let task = ScheduledTask(
            id: id, title: "Notification check: \(mode)", body: .prompt("Say hello in one sentence."),
            recurrence: .once(now.addingTimeInterval(20)), createdAt: now
        )
        guard await model.saveScheduledTask(task) else {
            record("probe save failed")
            return
        }
        await NotificationCentre.shared.reconcile(model.scheduledTasks)
        record("probe armed mode=\(mode) task=\(id)")
    }
}
#endif
