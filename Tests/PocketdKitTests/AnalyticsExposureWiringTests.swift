import Foundation
import Testing

@Suite("Analytics exposure wiring")
struct AnalyticsExposureWiringTests {
    @Test("purchase errors count the displayed priority, not StoreKit outcomes or a covered offer")
    func purchaseNoticePriority() throws {
        let store = try source("Store/ProStore.swift")
        let sheet = try source("Views/Pro/ProSheet.swift")
        let onlyViewEmits = !store.contains("recordAnalytics(.errorShown(area: .purchase")
            && !store.contains("recordAnalytics(.errorShown(area: .restore")
        let observesNotice = sheet.contains(".onChange(of: displayedError, initial: true)")
        let noteTakesPriority = sheet.contains("if let note { return .init(line: note, error: noteErrorCode.map")
        #expect(onlyViewEmits)
        #expect(observesNotice)
        #expect(noteTakesPriority)
    }

    private func source(_ file: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("App/Sources/\(file)"), encoding: .utf8)
    }

    @Test("local and typed detail entry points count from the actual detail, not twice from Root")
    func detailEntrances() throws {
        let privacy = try source("Views/You/PrivacyDetailsView.swift").contains(".onAppear { model.record(.screenViewed(screen: .privacyDetails)) }")
        let routine = try source("Views/Routines/RoutineResultView.swift").contains(".onAppear { model.record(.screenViewed(screen: .routineResult)) }")
        let root = try source("Views/RootView.swift").contains("guard screen != .privacyDetails, screen != .routineResult else { return }")
        #expect(privacy)
        #expect(routine)
        #expect(root)
    }

    @Test("price failures are observed without inventing a Buy action; server failures await a notice screen")
    func visibleErrors() throws {
        let paywall = try source("Views/Pro/ProSheet.swift").contains("if let error { model?.record(.errorShown(area: error.area, code: error.code)) }")
        let server = try source("State/AppModel+Server.swift")
        let creationDoesNotEmit = !server.components(separatedBy: "catch {").dropFirst().contains { $0.components(separatedBy: "}").first?.contains("record(.errorShown") == true }
        let devices = try source("Views/You/DevicesView.swift").contains("model.recordVisibleServerError()")
        let desk = try source("Views/You/DeskModeView.swift").contains("model.recordVisibleServerError()")
        #expect(paywall)
        #expect(creationDoesNotEmit)
        #expect(devices)
        #expect(desk)
    }

    @Test("retained Devices observers exclude covered routes, sheets and background phases")
    func serverVisibility() throws {
        let devices = try source("Views/You/DevicesView.swift")
        let activeAndUncovered = devices.contains("guard scenePhase == .active, !model.needsOnboarding, !model.deskMode,")
            && devices.contains("!navigator.isAskPresented, !showsPromo, !showsRequests else { return false }")
        let checksTopRoute = devices.contains("switch navigator.path.last {")
            && devices.contains("case .youPage(.devices), .youPage(.deskMode): return true")
        let gatesCallbacks = devices.contains("if analyticsNoticeIsVisible { model.recordVisibleServerError() }")
            && devices.contains(".onChange(of: analyticsNoticeIsVisible, initial: true)")
        #expect(activeAndUncovered)
        #expect(checksTopRoute)
        #expect(gatesCallbacks)
    }
}
