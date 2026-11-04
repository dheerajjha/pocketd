import Darwin
import SwiftUI
import UIKit
import XCTest

@MainActor
final class ScrollCompatibilityTests: XCTestCase {
    private var previousOverride: String?
    private var window: UIWindow?
    private var host: UIHostingController<AnyView>?

    override func setUp() async throws {
        previousOverride = ProcessInfo.processInfo.environment["POCKETD_FORCE_LEGACY_SCROLL_GEOMETRY"]
        setenv("POCKETD_FORCE_LEGACY_SCROLL_GEOMETRY", "1", 1)
    }

    override func tearDown() async throws {
        host?.rootView = AnyView(EmptyView())
        window?.isHidden = true
        window = nil
        host = nil
        if let previousOverride {
            setenv("POCKETD_FORCE_LEGACY_SCROLL_GEOMETRY", previousOverride, 1)
        } else {
            unsetenv("POCKETD_FORCE_LEGACY_SCROLL_GEOMETRY")
        }
    }

    func testLegacyObservationReportsScrollingWithoutChangingTheDelegate() async throws {
        let capture = GeometryCapture()
        let scrollView = try await mount(
            scrollContent.onPDScrollGeometryChange(for: PDScrollGeometry.self) { $0 } action: { _, value in
                capture.values.append(value)
            }
        )
        let delegate = scrollView.delegate
        let contentSize = scrollView.contentSize
        scrollView.setContentOffset(CGPoint(x: 0, y: 180), animated: false)
        try await waitUntil { capture.values.last?.contentOffset.y == 180 }

        XCTAssertTrue(scrollView.delegate === delegate)
        XCTAssertEqual(scrollView.contentSize, contentSize)
        XCTAssertEqual(capture.values.last?.contentSize, scrollView.contentSize)
        XCTAssertGreaterThan(capture.values.last?.visibleRect.height ?? 0, 0)
        XCTAssertGreaterThan((capture.values.last?.contentOffset.y ?? 0)
                             + (capture.values.last?.contentInsets.top ?? 0), 44,
                             "the existing detail-title threshold must still be observable")
    }

    func testContentGrowthAndComposerInsetsAreObserved() async throws {
        let capture = GeometryCapture()
        let state = ScrollFixtureState()
        let scrollView = try await mount(
            ScrollFixture(state: state).onPDScrollGeometryChange(for: PDScrollGeometry.self) { $0 } action: { _, value in
                capture.values.append(value)
            }
        )
        try await waitUntil { !capture.values.isEmpty }
        let grownHeight = scrollView.contentSize.height + 200
        state.extraHeight = 200
        try await waitUntil { capture.values.contains { $0.contentSize.height == grownHeight } }

        let previousInset = scrollView.adjustedContentInset.bottom
        state.bottomInset = 64
        try await waitUntil { scrollView.adjustedContentInset.bottom > previousInset }
        try await waitUntil { capture.values.last?.contentInsets.bottom == scrollView.adjustedContentInset.bottom }
        XCTAssertEqual(capture.values.last?.contentInsets.top, scrollView.adjustedContentInset.top)
    }

    func testUnmountingStopsObservation() async throws {
        let capture = GeometryCapture()
        let scrollView = try await mount(
            scrollContent.onPDScrollGeometryChange(for: PDScrollGeometry.self) { $0 } action: { _, value in
                capture.values.append(value)
            }
        )
        try await waitUntil { !capture.values.isEmpty }
        host?.rootView = AnyView(EmptyView())
        host?.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let count = capture.values.count
        scrollView.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(capture.values.count, count)
    }

    func testLegacyAndNativeGeometryAgreeIncludingSafeAreaAndBottomInsets() async throws {
        guard #available(iOS 18.0, *) else {
            throw XCTSkip("native geometry comparison requires iOS 18; the legacy tests still run on iOS 17")
        }
        let legacy = GeometryCapture()
        let native = GeometryCapture()
        let state = ScrollFixtureState()
        let scrollView = try await mount(
            ScrollFixture(state: state)
                .onPDScrollGeometryChange(for: PDScrollGeometry.self) { $0 } action: { _, value in
                    legacy.values.append(value)
                }
                .onScrollGeometryChange(for: PDScrollGeometry.self) { geometry in
                    PDScrollGeometry(contentOffset: geometry.contentOffset,
                                     contentInsets: geometry.contentInsets,
                                     contentSize: geometry.contentSize,
                                     visibleRect: geometry.visibleRect)
                } action: { _, value in
                    native.values.append(value)
                }
        )
        for offset: CGFloat in [180, 500, 0] {
            scrollView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            try await waitUntil(description: {
                "offset \(offset): legacy=\(String(describing: legacy.values.last)), native=\(String(describing: native.values.last))"
            }) {
                legacy.values.last?.contentOffset.y == offset && native.values.last?.contentOffset.y == offset
            }
            let lhs = try XCTUnwrap(legacy.values.last)
            let rhs = try XCTUnwrap(native.values.last)
            XCTAssertEqual(lhs.contentOffset, rhs.contentOffset)
            XCTAssertEqual(lhs.contentInsets, rhs.contentInsets)
            XCTAssertEqual(lhs.contentSize, rhs.contentSize)
            XCTAssertEqual(lhs.visibleRect, rhs.visibleRect)
        }
        let previousInset = scrollView.adjustedContentInset.bottom
        state.bottomInset = 64
        try await waitUntil { scrollView.adjustedContentInset.bottom > previousInset }
        try await waitUntil(description: {
            "composer inset: legacy=\(String(describing: legacy.values.last)), native=\(String(describing: native.values.last))"
        }) {
            legacy.values.last?.contentInsets.bottom == scrollView.adjustedContentInset.bottom
                && native.values.last?.contentInsets.bottom == scrollView.adjustedContentInset.bottom
        }
        XCTAssertEqual(legacy.values.last?.visibleRect, native.values.last?.visibleRect)
    }

    private var scrollContent: some View {
        ScrollFixture(state: ScrollFixtureState())
    }

    private func mount<Content: View>(_ content: Content) async throws -> UIScrollView {
        let host = UIHostingController(rootView: AnyView(content))
        let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = frame
        } else {
            window = UIWindow(frame: frame)
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.host = host
        self.window = window
        host.view.layoutIfNeeded()
        try await waitUntil {
            guard let scroll = Self.findScrollView(in: host.view) else { return false }
            return scroll.contentSize.height > 844
        }
        return try XCTUnwrap(Self.findScrollView(in: host.view))
    }

    private func waitUntil(description: () -> String = { "scroll observation" },
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard condition() else {
            XCTFail("\(description()) did not arrive before the deadline")
            throw ObservationTimeout()
        }
    }

    private static func findScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView { return scrollView }
        for child in view.subviews {
            if let scrollView = findScrollView(in: child) { return scrollView }
        }
        return nil
    }
}

private final class GeometryCapture {
    var values: [PDScrollGeometry] = []
}

@MainActor
private final class ScrollFixtureState: ObservableObject {
    @Published var extraHeight: CGFloat = 0
    @Published var bottomInset: CGFloat = 0
}

private struct ScrollFixture: View {
    @ObservedObject var state: ScrollFixtureState

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(0..<80) { index in
                    Text("Row \(index)").frame(maxWidth: .infinity).frame(height: 44)
                }
                Color.clear.frame(height: state.extraHeight)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: state.bottomInset)
        }
    }
}

private struct ObservationTimeout: Error {}
