import SwiftUI
import UIKit

/// The geometry consumed by title fades and conversation following. Both OS
/// paths report the scroll view's real offset, insets, content and viewport.
struct PDScrollGeometry: Equatable {
    var contentOffset: CGPoint
    var contentInsets: EdgeInsets
    var contentSize: CGSize
    var visibleRect: CGRect

    static let zero = PDScrollGeometry(
        contentOffset: .zero, contentInsets: EdgeInsets(),
        contentSize: .zero, visibleRect: .zero
    )

    static var forcesLegacyObserver: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["POCKETD_FORCE_LEGACY_SCROLL_GEOMETRY"] == "1"
        #else
        false
        #endif
    }
}

extension View {
    /// Keep native observation on iOS 18+. On iOS 17, observe the underlying
    /// UIScrollView without changing its layout, delegate or scrolling rules.
    @ViewBuilder
    func onPDScrollGeometryChange<Value: Equatable>(
        for type: Value.Type,
        of transform: @escaping (PDScrollGeometry) -> Value,
        action: @escaping (Value, Value) -> Void
    ) -> some View {
        if #available(iOS 18.0, *), !PDScrollGeometry.forcesLegacyObserver {
            self.onScrollGeometryChange(for: type) { geometry in
                transform(PDScrollGeometry(
                    contentOffset: geometry.contentOffset,
                    contentInsets: geometry.contentInsets,
                    contentSize: geometry.contentSize,
                    visibleRect: geometry.visibleRect
                ))
            } action: { old, new in
                action(old, new)
            }
        } else {
            self.background {
                LegacyScrollGeometryObserver(transform: transform, action: action)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct LegacyScrollGeometryObserver<Value: Equatable>: UIViewRepresentable {
    var transform: (PDScrollGeometry) -> Value
    var action: (Value, Value) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(transform: transform, action: action)
    }

    func makeUIView(context: Context) -> ScrollProbeView {
        let view = ScrollProbeView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.onResolve = { [weak coordinator = context.coordinator] scrollView in
            coordinator?.attach(to: scrollView)
        }
        return view
    }

    func updateUIView(_ uiView: ScrollProbeView, context: Context) {
        context.coordinator.transform = transform
        context.coordinator.action = action
        uiView.resolveAfterLayout()
    }

    static func dismantleUIView(_ uiView: ScrollProbeView, coordinator: Coordinator) {
        uiView.onResolve = nil
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator {
        var transform: (PDScrollGeometry) -> Value
        var action: (Value, Value) -> Void
        private weak var scrollView: UIScrollView?
        private var observations: [NSKeyValueObservation] = []
        private var previousValue: Value
        private var updateScheduled = false

        init(transform: @escaping (PDScrollGeometry) -> Value,
             action: @escaping (Value, Value) -> Void) {
            self.transform = transform
            self.action = action
            previousValue = transform(.zero)
        }

        func attach(to scrollView: UIScrollView) {
            guard self.scrollView !== scrollView else { return }
            stopObserving()
            self.scrollView = scrollView
            previousValue = transform(.zero)
            // UIKit geometry changes occur on the main thread. Defer the
            // callback past layout and coalesce its four observation sources.
            let changed: @MainActor @Sendable () -> Void = { [weak self] in self?.scheduleUpdate() }
            observations = [
                scrollView.observe(\.contentOffset) { _, _ in
                    MainActor.assumeIsolated { changed() }
                },
                scrollView.observe(\.contentSize) { _, _ in
                    MainActor.assumeIsolated { changed() }
                },
                scrollView.observe(\.bounds) { _, _ in
                    MainActor.assumeIsolated { changed() }
                },
                scrollView.observe(\.adjustedContentInset) { _, _ in
                    MainActor.assumeIsolated { changed() }
                }
            ]
            scheduleUpdate()
        }

        func stopObserving() {
            observations.forEach { $0.invalidate() }
            observations.removeAll()
            scrollView = nil
        }

        private func scheduleUpdate() {
            guard !updateScheduled else { return }
            updateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                updateScheduled = false
                guard let scrollView else { return }
                let inset = scrollView.adjustedContentInset
                let value = transform(PDScrollGeometry(
                    contentOffset: scrollView.contentOffset,
                    contentInsets: EdgeInsets(top: inset.top, leading: inset.left,
                                              bottom: inset.bottom, trailing: inset.right),
                    contentSize: scrollView.contentSize,
                    visibleRect: CGRect(origin: scrollView.contentOffset, size: scrollView.bounds.size)
                ))
                guard value != previousValue else { return }
                let old = previousValue
                previousValue = value
                action(old, value)
            }
        }
    }
}

/// A non-rendering anchor next to SwiftUI's scroll view. Resolve from the
/// nearest common ancestor rather than searching a window or another screen.
private final class ScrollProbeView: UIView {
    var onResolve: ((UIScrollView) -> Void)?
    private var resolutionScheduled = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        resolveAfterLayout()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        resolveAfterLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        resolveAfterLayout()
    }

    func resolveAfterLayout() {
        guard !resolutionScheduled else { return }
        resolutionScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            resolutionScheduled = false
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor, !(view is UIWindow) {
                if let scrollView = Self.findScrollView(in: view) {
                    onResolve?(scrollView)
                    return
                }
                ancestor = view.superview
            }
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
