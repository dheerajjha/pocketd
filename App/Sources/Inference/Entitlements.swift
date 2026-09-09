import Foundation

enum Entitlements {
    /// Whether this build actually carries the increased memory limit.
    ///
    /// Read from the embedded provisioning profile rather than from an
    /// Info.plist flag, because the two can disagree: a flag is set in the
    /// project spec, while the entitlement only exists if the profile granted
    /// it. A build signed without the capability would otherwise claim 58% of
    /// RAM and be jetsammed at 45%, and the Models tab would recommend a model
    /// the device cannot hold.
    ///
    /// `SecTaskCopyValueForEntitlement` would be the direct route but is not
    /// exposed on iOS, so the profile is parsed instead. There is none in a
    /// simulator build, where the answer does not matter anyway: the budget is
    /// computed from the host Mac's RAM.
    static let hasIncreasedMemoryLimit: Bool = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url)
        else { return false }

        // The profile is CMS-signed; the plist sits inside it as plain text.
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8))
        else { return false }

        let plist = data[start.lowerBound..<end.upperBound]
        guard let root = try? PropertyListSerialization.propertyList(
                    from: plist, options: PropertyListSerialization.ReadOptions(), format: nil
              ) as? [String: Any],
              let entitlements = root["Entitlements"] as? [String: Any]
        else { return false }

        return entitlements["com.apple.developer.kernel.increased-memory-limit"] as? Bool ?? false
    }()
}
