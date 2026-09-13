import Foundation
import PocketdKit
import UIKit

/// Fills in the log's header from the bundle and the device.
///
/// Here rather than in PocketdKit because every value below comes from UIKit or
/// this app's own `Info.plist`, and that package is built for macOS to run its
/// tests. `DiagnosticLog.Environment` is the seam.
enum DiagnosticEnvironment {

    /// The hardware identifier — `iPhone17,1` and so on.
    ///
    /// `UIDevice.current.model` is not this: it returns the string "iPhone" on
    /// every iPhone ever made, which tells a reader nothing about the phone a
    /// bug reproduced on. `hw.machine` is the useful one, it is shared by
    /// millions of devices, and it is not an identifier for a person.
    static var deviceModel: String {
        var system = utsname()
        uname(&system)
        let identifier = withUnsafeBytes(of: &system.machine) { raw in
            // `machine` is a fixed-size C char array; everything after the
            // first NUL is padding and would otherwise ride along as zero bytes.
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return identifier.isEmpty ? "unknown" : identifier
    }

    static func current(modelID: String?, contextTokens: Int?) -> DiagnosticLog.Environment {
        let info = Bundle.main.infoDictionary
        return DiagnosticLog.Environment(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
            build: info?["CFBundleVersion"] as? String ?? "?",
            deviceModel: deviceModel,
            systemVersion: UIDevice.current.systemVersion,
            modelID: modelID,
            contextTokens: contextTokens
        )
    }
}
