import Foundation
import PocketdKit
import SwiftUI

/// The phone as a server for other devices: the listener, pairing, Bonjour and
/// the configuration they share.
@MainActor
extension AppModel {

    func startServer() async {
        serverShouldRun = true
        UserDefaults.standard.set(true, forKey: Keys.serverShouldRun)
        lastServerError = nil
        // Before the listener opens, so the very first request from another
        // device already gets what Server settings says. Here rather than only
        // in `applyConfiguration`, because a launch never applies anything: the
        // stored settings reach the engine on the way up or not at all.
        await pushServerSettingsToEngine()
        do {
            try await server.apply(configuration)
            try await server.start()
            servingSince = Date()
            // On this line and not at the top of the method, because a bind
            // that fails throws above: a port already in use would otherwise be
            // counted as the server having started. The count does include the
            // restart after every suspension — iOS closes the socket without
            // telling anyone and `reconcileAfterForeground` puts it back — and
            // "the listener came up" is what this event honestly means.
            analytics.record(.serverStarted)
            // A code is only worth showing until someone has used one. After
            // that the laptop has the key and the phone should stop displaying
            // six digits it no longer needs.
            if await server.pairing.snapshot().hasPaired == false {
                await server.openPairing()
            }
            await advertise()
        } catch {
            lastServerError = friendlyMessage(for: error)
        }
    }

    func stopServer() async {
        serverShouldRun = false
        UserDefaults.standard.set(false, forKey: Keys.serverShouldRun)
        // Only where this app is the one ending it. A suspension kills the
        // listener without running this method, so a stop recorded later would
        // be measured across hours of a phone in a pocket — app-open time,
        // which `serverStopped` documents itself as deliberately not being.
        // The price is that starts outnumber stops, and the difference is
        // suspensions rather than anything anyone did.
        if let since = servingSince {
            analytics.record(.serverStopped(servedSeconds: Date().timeIntervalSince(since)))
            servingSince = nil
        }
        await server.stop()
        await server.closePairing()
        bonjour.stop()
    }

    /// Called on every return to the foreground. iOS closes the listening socket
    /// when the app suspends without telling anyone, so the only correct thing to
    /// do is re-establish it and let the user see the address again.
    func reconcileAfterForeground() async {
        guard serverShouldRun else { return }
        // liveState() reconciles against the socket. currentState() would report
        // the `.running` we last wrote, which is exactly the stale value this
        // method exists to repair — it would early-return in the only case that
        // matters.
        if await server.liveState().isRunning {
            applyIdleTimer(running: true)
            return
        }
        await server.stop()   // release any half-dead socket and reset admission counters
        await startServer()
    }

    func applyConfiguration(_ new: ServerConfiguration) async {
        configuration = new
        // The context limit moves the memory ceiling, so every fit badge and
        // the download gate have to be recomputed against the new one.
        governor?.updateThermalTolerance(new.thermalTolerance)
        budget.servedContextTokens = new.maxContextTokens
        await store.updateBudget(budget)
        await pushServerSettingsToEngine()
        do {
            try await server.apply(new)
            lastServerError = nil
        } catch {
            lastServerError = friendlyMessage(for: error)
        }
        governor?.updateBatteryFloor(new.pauseBelowBatteryLevel)
        // Not covered by the observer: toggling keep-awake in Settings produces
        // no server transition, so the new setting would not take hold until the
        // next start or stop.
        applyIdleTimer(running: await server.liveState().isRunning)
        await advertise()
    }

    func clearLog() async {
        await server.log.clear()
    }

    /// The server's own settings, handed to the engine that answers it.
    ///
    /// Three of them, and two were never wired at all: "Let the model think
    /// first" reached only the phone's own chat (which never thinks now —
    /// `ThinkingPolicy`), and the context limit reached the memory estimate and
    /// what the server *told* clients while the engine kept its 4,096-token
    /// window — so a client trusting a raised limit got "context exceeded" on
    /// prompts the server had just advertised room for. The engine applies all
    /// three lazily, on the next request that needs them; nothing reloads here.
    func pushServerSettingsToEngine() async {
        await engine.updateDefaultSampling(configuration.sampling)
        await engine.updateContextTokens(configuration.maxContextTokens)
        await engine.updateThinking(networkAllowed: configuration.reasoningEnabled)
    }

    /// Publishes the service once the listener is actually up, so browsers are
    /// never pointed at a port nothing is bound to.
    private func advertise() async {
        guard case let .running(_, port) = await server.liveState() else { return }
        #if canImport(UIKit)
        let name = UIDevice.current.name
        #else
        let name = "Pocketd"
        #endif
        bonjour.start(
            port: port,
            name: name,
            model: servedModelID,
            requiresAuth: configuration.requiresAuth
        )
    }

    /// The brain other devices are answered by, as far as the phone knows.
    ///
    /// The server's own engine's, never the phone's: while the phone uses
    /// Apple's model, `loadedModelID` names that, and the server never serves
    /// it — advertising its id would point a laptop at a brain that 404s. nil
    /// means none is in memory yet; the first request loads the first
    /// download on the phone (`resolveModel`).
    var servedModelID: String? {
        if let id = downloadedResidentID { return id }
        guard let id = loadedModelID, id != ModelRecord.builtInID else { return nil }
        return id
    }

    /// The served brain's name for a screen, or nil. Never the raw id.
    var servedBrainName: String? {
        guard let id = servedModelID else { return nil }
        return (installed + catalog).first { $0.id == id }?.displayName
    }

    /// Opens a fresh pairing code. Always allowed while serving — after a
    /// pairing, after five wrong tries, over a live code — because a second
    /// laptop, or a browser that forgot its key, has no other way in.
    func newPairingCode() async {
        await server.openPairing()
    }

    var serverURL: URL? {
        guard case let .running(host, port) = serverState else { return nil }
        return URL(string: "http://\(host):\(port)")
    }

    /// The address as a person types it into a browser: no scheme, which every
    /// browser adds by itself, and which only makes the line longer to read
    /// off a phone. `serverURL` is what gets copied.
    var laptopAddress: String? {
        guard case let .running(host, port) = serverState else { return nil }
        return "\(host):\(port)"
    }

    /// The one grey line the You root's "Use from your laptop" row shows.
    var laptopAccessSummary: String {
        switch serverState {
        case .starting:
            return "Starting…"
        case let .running(host, _):
            switch condition {
            case .ok: return "On · \(host)"
            case .thermal: return "Paused while your iPhone cools down"
            case .battery: return "Paused, battery low"
            }
        case .failed:
            return "Couldn't start"
        case .stopped:
            // Wanted on, socket gone: iOS closed it while Pocketd was in the
            // background, and coming back puts it back.
            return serverShouldRun ? "Starting…" : "Off"
        }
    }

    /// `serverState` is a mirror updated asynchronously by the observer, so every
    /// caller that reads it here would set the flag from the pre-transition
    /// value — backwards, every time. Callers pass the truth instead.
    func applyIdleTimer(running: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = configuration.keepAwakeWhileServing && running
        #endif
    }

    func persistConfiguration() {
        configurationStore.save(configuration)
    }

    /// Errors reach the Other devices page, so they are written for whoever is
    /// holding the phone: one sentence, and where to fix it. The previous
    /// version matched on the substring "48" — which never fired for the case
    /// it was written for, because a busy port surfaces as a five-second
    /// timeout rather than EADDRINUSE, and would false-positive on any error
    /// containing those digits.
    private func friendlyMessage(for error: any Error) -> String {
        let text = String(describing: error).lowercased()
        // A busy port shows up as a listener that never came up, so both
        // spellings get the same sentence.
        if text.contains("timed out") || text.contains("timeout") || text.contains("in use") || text.contains("eaddrinuse") {
            return "Another app is using port \(configuration.port). Pick another in Server settings."
        }
        if text.contains("permission") || text.contains("denied") {
            return "iOS blocked it. Allow Local Network for Pocketd in Settings › Privacy & Security › Local Network."
        }
        // Never the error itself: its description is a socket library's, and
        // it reached the screen verbatim. The log keeps the fact that it
        // happened; the person gets what to do.
        DiagnosticLog.record(.failure(area: .server, code: "start_failed"))
        return "Pocketd couldn't start serving. Try again, or pick another port in Server settings."
    }
}
