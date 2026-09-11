import Testing
import Foundation
@testable import PocketdKit

@Suite("Server version")
struct ServerVersionTests {
    /// The version the app is built with, read from the project spec.
    ///
    /// project.yml rather than the generated Xcode project, because the
    /// project is generated and gitignored — it may not exist on a clean
    /// checkout, and on CI it definitely does not.
    private func marketingVersion() throws -> String? {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            directory.deleteLastPathComponent()
            let candidate = directory.appendingPathComponent("project.yml")
            guard let text = try? String(contentsOf: candidate, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.contains("MARKETING_VERSION:") {
                return line
                    .split(separator: ":", maxSplits: 1)[1]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return nil
    }

    @Test("the wire version matches the version the app ships as")
    func matchesMarketingVersion() throws {
        // Two independent sources compared against each other, which is the
        // only kind of check worth having here. Asserting the constant against
        // itself would pass forever and catch nothing — and this repo has
        // shipped a test that did exactly that.
        //
        // The drift this exists for was real and silent: MARKETING_VERSION went
        // to 1.0.0 for the App Store while PocketdKit.version stayed at 0.1.0,
        // so a paired laptop asking /api/version — which Ollama clients
        // version-gate on — was told the wrong number by a running server.
        guard let marketing = try marketingVersion() else {
            // A consumer of this package as a dependency has no project.yml.
            // Skipping beats failing someone else's build.
            return
        }
        #expect(PocketdKit.version == marketing,
                "PocketdKit.version is \(PocketdKit.version) but the app ships as \(marketing)")
    }

    @Test("it parses as a semantic version")
    func semantic() {
        // Ollama clients version-gate on /api/version and some refuse to talk
        // to anything that does not parse.
        let parts = PocketdKit.version.split(separator: ".")
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { Int($0) != nil })
    }

    @Test("the fingerprint carries the same number")
    func fingerprint() {
        #expect(PocketdKit.systemFingerprint == "pocketd-\(PocketdKit.version)")
    }
}
