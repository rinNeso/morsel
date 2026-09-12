#if DEBUG
import Foundation
import SwiftUI
import UIKit

/// Development-only interaction logging.
///
/// Exists so "this feels clunky" can be checked against what actually happened
/// — hit-target sizes, resolved frames, tap coordinates, repeated taps that
/// suggest something did not respond — without anyone assembling screenshots.
///
/// Wrapped in `#if DEBUG` in its entirety: this never ships. It writes JSONL to
/// Application Support and makes no network calls, which also means it can be
/// pulled off the device without the owner doing anything:
///
///     xcrun devicectl device copy from --device <udid> \
///       --domain-type appDataContainer --domain-identifier com.rinneso.morsel \
///       --source Library/Application\ Support --destination ./devlog
@MainActor
final class DevLog {
    static let shared = DevLog()

    private var handle: FileHandle?
    private var buffer: [Event] = []
    private var flushTask: Task<Void, Never>?
    /// Last tap, to spot the same spot being hit repeatedly — the strongest
    /// available hint that a control did not respond.
    private var lastTap: (point: CGPoint, at: Date)?

    private static let repeatRadius: CGFloat = 44
    private static let repeatWindow: TimeInterval = 1.5

    struct Event: Codable {
        let at: String
        let kind: String
        var x: Double?
        var y: Double?
        var name: String?
        var width: Double?
        var height: Double?
        var detail: String?
        /// Set when this tap landed close to the previous one, soon after it.
        var repeatOfPrevious: Bool?
        /// True when a logged frame is below the 44pt minimum HIG asks for.
        var belowMinimumTarget: Bool?
    }

    private init() {
        guard let url = Self.fileURL() else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        try? handle?.seekToEnd()
        record(Event(at: Self.stamp(), kind: "session-start", detail: Self.deviceSummary()))
    }

    static func fileURL() -> URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        .appendingPathComponent("devlog.jsonl")
    }

    // MARK: Recording

    func tap(at point: CGPoint) {
        let now = Date()
        var event = Event(at: Self.stamp(now), kind: "tap", x: point.x, y: point.y)

        if let last = lastTap,
           now.timeIntervalSince(last.at) < Self.repeatWindow,
           hypot(point.x - last.point.x, point.y - last.point.y) < Self.repeatRadius {
            event.repeatOfPrevious = true
        }
        lastTap = (point, now)
        record(event)
    }

    /// Resolved frame of an instrumented view, so exact positions and target
    /// sizes can be checked after the fact.
    func frame(_ name: String, _ rect: CGRect) {
        record(Event(
            at: Self.stamp(),
            kind: "frame",
            x: rect.origin.x, y: rect.origin.y,
            name: name,
            width: rect.width, height: rect.height,
            belowMinimumTarget: (rect.width < 44 || rect.height < 44) ? true : nil
        ))
    }

    func state(_ name: String, _ value: String) {
        record(Event(at: Self.stamp(), kind: "state", name: name, detail: value))
    }

    /// Dropped by shaking the phone: "whatever just happened felt wrong".
    /// Without this the log is a haystack; with it, the surrounding couple of
    /// seconds are exactly the evidence needed.
    func mark() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        record(Event(at: Self.stamp(), kind: "MARK", detail: "felt wrong"))
        flush()
    }

    // MARK: Writing

    private func record(_ event: Event) {
        buffer.append(event)
        guard flushTask == nil else { return }
        // Batched: a tap-by-tap fsync would itself introduce the stutter this
        // is supposed to be measuring.
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.flushTask = nil
            self?.flush()
        }
    }

    func flush() {
        guard let handle, !buffer.isEmpty else { return }
        let encoder = JSONEncoder()
        var data = Data()
        for event in buffer {
            if let line = try? encoder.encode(event) {
                data.append(line)
                data.append(0x0A)
            }
        }
        buffer.removeAll()
        try? handle.write(contentsOf: data)
    }

    // MARK: Helpers

    private static func stamp(_ date: Date = Date()) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt))
    }

    private static func deviceSummary() -> String {
        let screen = UIScreen.main.bounds
        return "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion) "
            + "\(Int(screen.width))x\(Int(screen.height))@\(Int(UIScreen.main.scale))x"
    }
}

// MARK: - Capture

/// Transparent overlay that records every touch location. `hitTest` returning
/// nil means it never consumes the touch — it only watches them go past, which
/// is the point: this sees taps that land on nothing at all, which SwiftUI
/// gestures by definition cannot.
private final class TouchWatchingView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if event?.type == .touches {
            DevLog.shared.tap(at: convert(point, to: nil))
        }
        return nil
    }
}

private struct TouchWatcher: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { TouchWatchingView() }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// Becomes first responder so shakes reach `motionEnded`.
private final class ShakeWatchingView: UIView {
    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        becomeFirstResponder()
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        guard motion == .motionShake else { return }
        DevLog.shared.mark()
    }
}

private struct ShakeWatcher: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { ShakeWatchingView() }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

extension View {
    /// Root-level instrumentation: every touch, plus shake-to-mark.
    func devLogging() -> some View {
        overlay {
            // Deliberately NOT `.allowsHitTesting(false)`: that sets
            // isUserInteractionEnabled = false, so UIKit skips hitTest
            // altogether and the watcher would silently see nothing. Returning
            // nil from hitTest is what keeps it from consuming touches.
            ZStack {
                TouchWatcher()
                ShakeWatcher()
            }
            .accessibilityHidden(true)
        }
    }

    /// Report this view's resolved frame under a name, so its position and
    /// size can be inspected later.
    func devLogged(_ name: String) -> some View {
        onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { rect in
            DevLog.shared.frame(name, rect)
        }
    }
}
#else
import CoreGraphics
import SwiftUI

// Release builds get an inert stub with the same shape, so call sites never
// need an #if of their own and cannot accidentally fail to compile here.
@MainActor
final class DevLog {
    static let shared = DevLog()
    private init() {}

    func tap(at point: CGPoint) {}
    func frame(_ name: String, _ rect: CGRect) {}
    func state(_ name: String, _ value: String) {}
    func mark() {}
    func flush() {}
    static func fileURL() -> URL? { nil }
}

extension View {
    func devLogging() -> some View { self }
    func devLogged(_ name: String) -> some View { self }
}
#endif
