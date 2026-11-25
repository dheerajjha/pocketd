/// A fresh composer owns no audio resources. Only Start calls the factories;
/// Stop and deinit can release only what that particular Start acquired.
public final class DictationMicrophone<Tap> {
    public typealias Release = () -> Void
    public typealias InstalledTap = (startEngine: () throws -> Void, removeTapAndStopEngine: Release)

    private let activate: () throws -> Release
    private let install: (Tap) throws -> InstalledTap
    private var release: Release?

    public init(activate: @escaping () throws -> Release, install: @escaping (Tap) throws -> InstalledTap) {
        self.activate = activate
        self.install = install
    }

    public func start(tap: Tap) throws {
        stop()
        let deactivate = try activate()
        release = deactivate
        do {
            let installed = try install(tap)
            release = { installed.removeTapAndStopEngine(); deactivate() }
            try installed.startEngine()
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        let owned = release
        release = nil
        owned?()
    }

    deinit { release?() }
}
