#if DEBUG
import PocketdKit
import SwiftUI

/// Puts a page under You into a named state, for a screenshot.
///
/// Every state worth photographing on this tab is a state the simulator cannot
/// reach on its own: a granted calendar with the switch on, a server with a
/// live address and an open pairing code, a brain that is actually resident.
/// Reaching them by driving the UI needs an automation harness pointed at one
/// specific simulator, and on a machine running several at once that is a
/// pointed gun.
///
/// So the states are asked for at launch instead, the same way
/// `scripts/sim-demo.sh` asks for a seeded calendar. Entirely inside `#if
/// DEBUG`, imports included, so a Release build has no path through any of it —
/// not even a dead branch.
///
///     xcrun simctl launch <udid> dev.pocketd.app \
///         -pocketd.seedDemo -pocketd.skipIntro \
///         -pocketd.stage.calendar -pocketd.stage.health \
///         -pocketd.stage.serve -pocketd.stage.brain \
///         -pocketd.stage.route brain
///
/// `-pocketd.stage.route addBrain -pocketd.stage.search qwen3` lands on More
/// brains › Search Hugging Face with "qwen3" typed. Any `-pocketd.stage.*`
/// argument pushes You onto Today first.
enum YouStage {
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    private static func asked(_ name: String) -> Bool {
        arguments.contains("-pocketd.stage.\(name)")
    }

    /// The value after `-pocketd.stage.route`, if there is one.
    private static var route: YouRoute? {
        guard let index = arguments.firstIndex(of: "-pocketd.stage.route"),
              arguments.indices.contains(index + 1) else { return nil }
        switch arguments[index + 1] {
        case "brain": return .brain
        case "addBrain", "moreBrains", "search": return .addBrain
        case "brainAdvanced": return .brainAdvanced
        case "devices": return .devices
        case "privacy": return .privacy
        case "privacyDetails": return .privacyDetails
        case "settings": return .settings
        case "instructions": return .instructions
        case "diagnostics": return .diagnostics
        default: return nil
        }
    }

    /// The value after `-pocketd.stage.sheet`: which of the You page's sheets
    /// to open (`name`, `about`). Named rather than tapped for the reason the
    /// whole type exists.
    static var sheet: String? {
        guard let index = arguments.firstIndex(of: "-pocketd.stage.sheet"),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// The value after `-pocketd.stage.search`: what to type into Search
    /// Hugging Face before the screenshot. More brains opens the search when
    /// it is set.
    static var searchQuery: String? {
        guard let index = arguments.firstIndex(of: "-pocketd.stage.search"),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// The value after `-pocketd.stage.builtIn`: Apple's model as this phone
    /// might report it — `turnedOff`, `unsupportedLanguage`, `notEligible`,
    /// `gettingReady` — for the Brain page states a simulator with Apple
    /// Intelligence on cannot reach.
    static var builtInAvailability: BuiltInBrainAvailability? {
        guard let index = arguments.firstIndex(of: "-pocketd.stage.builtIn"),
              arguments.indices.contains(index + 1) else { return nil }
        return BuiltInBrainAvailability(rawValue: arguments[index + 1])
    }

    /// The value after `-pocketd.stage.scrollTo`: one of the section ids on the
    /// You page (`abilities`, `brain`, `privacy`, `devices`, `about`,
    /// `settings`).
    static var scrollAnchor: String? {
        guard let index = arguments.firstIndex(of: "-pocketd.stage.scrollTo"),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// Whether this launch asked for anything at all. Checked first so an
    /// ordinary run does no work and takes no different path.
    static var isRequested: Bool {
        arguments.contains { $0.hasPrefix("-pocketd.stage.") }
    }

    /// Pushes You onto Today before anything renders.
    ///
    /// Separate from `apply` and called from the app rather than from a view,
    /// because the view that would ask is the one that only exists once You
    /// is on screen. A `pocketd://you` URL would do the same job, and iOS puts
    /// its own "Open in Pocketd?" alert over the screenshot when a URL arrives
    /// from outside the app.
    @MainActor
    static func selectTabIfRequested(_ navigator: Navigator) {
        guard isRequested else { return }
        navigator.go(.you)
    }

    @MainActor
    static func apply(model: AppModel, navigator: Navigator) async {
        guard isRequested else { return }

        if asked("calendar") { model.calendarToolsEnabled = true }
        if asked("reminders") { model.reminderToolsEnabled = true }
        if asked("health") { model.healthToolsEnabled = true }

        if asked("brain") { await stageBrain(model) }
        if asked("serve") {
            await model.startServer()
            await model.newPairingCode()
        }

        if let availability = builtInAvailability {
            // After launch's own reading has landed, or it would overwrite
            // this one a moment later.
            try? await Task.sleep(for: .seconds(1.5))
            model.builtInAvailability = availability
        }

        if let route { navigator.push(route) }
        // Last, because desk mode replaces the whole shell and nothing after it
        // would run on a screen anybody can see.
        if asked("deskMode") { model.deskMode = true }
    }

    /// The smallest thing in the catalogue, downloaded and resident.
    ///
    /// 360M is the only one that fits a simulator's budget, and it is the one
    /// the brief names. Tools are refused for it, which is exactly why the
    /// screens have to look right without them.
    @MainActor
    private static func stageBrain(_ model: AppModel) async {
        guard let record = ModelCatalog.model(withID: "smollm2-360m") else { return }
        // Waited for rather than asked once. `bootstrap()` fills both the
        // snapshot and the store's own manifest asynchronously and this task
        // can easily run first, and a download started for a file already on
        // disk fails on the move and leaves a red banner over the screenshot.
        var onDisk = false
        for _ in 0..<20 where !onDisk {
            if model.isInstalled(record) {
                onDisk = true
            } else {
                let manifest = await model.manifestInstalled()
                onDisk = manifest.contains { $0.id == record.id }
            }
            if !onDisk { try? await Task.sleep(for: .milliseconds(250)) }
        }
        if !onDisk {
            model.download(record)
            // Polled rather than awaited: the download is driven by a
            // URLSession delegate that publishes into `transfers`, and there is
            // no continuation to hang on. Two minutes is four times what 386 MB
            // takes on this machine.
            for _ in 0..<240 where !model.isInstalled(record) {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        // Wait for the snapshot to catch up with the disk before loading, for
        // the same reason.
        for _ in 0..<20 where !model.isInstalled(record) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard model.isInstalled(record), model.loadedModelID != record.id else { return }
        await model.loadModel(record)
    }
}
#endif
