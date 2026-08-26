import Testing
import Foundation
import SwiftUI
import AppKit
@testable import TokiMonitor

// MARK: - What a rendered panel actually announces
//
// `PanelAccessibilityTests` pins the sentence; this pins the WIRING — that the
// sentence reaches the accessibility tree of a real `PanelContainerView` in
// every one of the five states. The two are separable failures: an announcement
// composed correctly and never attached reads to VoiceOver as silence.
//
// The tree is read through AppKit's own accessibility API on a hosted view,
// which is the same interface VoiceOver goes through.

@MainActor
enum PanelAccessibilityProbe {

    /// The hosting windows, kept alive for the length of the run. A window that
    /// deallocates while its hosted view is still being walked takes the
    /// accessibility tree with it, and the walk faults.
    private static var windows: [NSWindow] = []

    /// Every accessibility label in the tree under a hosted view.
    static func labels<V: View>(of view: V,
                                size: CGSize = CGSize(width: 320, height: 220)) -> [String] {
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width,
                                                              height: size.height)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        windows.append(window)
        var out: [String] = []
        var seen = 0
        // The accessibility methods are an Obj-C category on NSObject rather
        // than a Swift protocol conformance, so `as? NSAccessibilityProtocol`
        // fails on the very elements that answer them. Dynamic dispatch through
        // `AnyObject` is how they are reached.
        func walk(_ node: Any) {
            seen += 1
            guard seen < 5_000 else { return }
            let object = node as AnyObject
            if let label = object.accessibilityLabel?(), !label.isEmpty {
                out.append(label)
            }
            if let value = object.value(forKey: "accessibilityValue") as? String,
               !value.isEmpty {
                out.append(value)
            }
            for child in (object.accessibilityChildren?() ?? []) ?? [] { walk(child) }
        }

        // SwiftUI populates its accessibility tree during a draw, not during
        // layout — and the first hosted view in the process needs a second
        // pass before the tree exists at all. Walking once gives an empty
        // AXGroup and a test that passes for the wrong reason, so the render is
        // repeated until something appears.
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
            }
            // A draw is not enough on its own: the tree is published on a later
            // turn of the run loop, and the FIRST hosted view in the process
            // needs that turn before it has one at all. Without the spin this
            // suite passes everywhere except its first case, which is the worst
            // possible flake — it looks like a real accessibility failure.
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            out = []
            seen = 0
            walk(host)
            if !out.isEmpty { break }
        }
        return out
    }

    /// The single label that names the whole panel — the one a VoiceOver reader
    /// hears on landing.
    static func panelLabel(_ title: String, of labels: [String]) -> String? {
        labels.first { $0.hasPrefix(title) }
    }
}

@Suite("Panel accessibility, as rendered", .serialized)
@MainActor
struct PanelAccessibilityRenderTests {

    private func labels(for state: PanelState, value: String? = nil) -> [String] {
        PanelAccessibilityProbe.labels(of:
            PanelContainerView(
                title: "Total tokens",
                isEditing: false,
                state: state,
                panelType: .timeSeries,
                valueSummary: value,
                onDelete: {},
                onEdit: {},
                onRetry: {},
                onInspect: {}
            ) { Color.clear }
        )
    }

    @Test("the panel's own label reaches the accessibility tree in every state",
          arguments: PanelSnapshotState.allCases)
    func everyStateAnnouncesItself(state: PanelSnapshotState) {
        let found = labels(for: state.panelState, value: "2 series, opus, latest 24K")
        let panel = PanelAccessibilityProbe.panelLabel("Total tokens", of: found)
        #expect(panel != nil,
                "\(state.rawValue): nothing in the tree names the panel — \(found)")
        guard let panel else { return }
        #expect(panel.contains(PanelType.timeSeries.displayName),
                "\(state.rawValue): the reader is not told what kind of panel this is")
        if case .loaded = state.panelState {
            #expect(panel.contains("2 series"),
                    "loaded: the panel does not speak its value")
        } else {
            #expect(panel.contains(state.panelState.title),
                    "\(state.rawValue): the state is not named — heard as silence")
        }
    }

    @Test("a failed panel carries its reason all the way to the tree")
    func failureReachesTheTree() {
        let found = labels(for: .failed(reason: "connection refused (127.0.0.1:9494)"))
        #expect(found.contains { $0.contains("connection refused (127.0.0.1:9494)") },
                "the reason never reached assistive technology: \(found)")
    }

    @Test("a partially failed panel names the query that did not answer")
    func partialFailureIsAnnounced() {
        let found = PanelAccessibilityProbe.labels(of:
            PanelContainerView(
                title: "Total tokens",
                isEditing: false,
                state: .loaded,
                panelType: .timeSeries,
                valueSummary: "1.2M",
                onDelete: {},
                onEdit: {},
                failedTargets: ["B": "unknown metric"]
            ) { Color.clear }
        )
        #expect(found.contains { $0.contains("unknown metric") },
                "the partial-failure badge is visual only: \(found)")
    }
}
