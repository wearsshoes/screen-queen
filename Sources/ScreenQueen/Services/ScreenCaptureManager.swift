import Foundation
@preconcurrency import ScreenCaptureKit
import CoreImage

/// Captures a live, low-frame-rate feed of each display's contents — *excluding
/// Screen Queen's own arranger overlay* — so each tile can show what's really on that
/// screen. One `SCStream` per display; the latest frame is cached as a `CGImage`
/// keyed by display id, and `onFrame` fires (on the main actor) when any updates so
/// the canvas can repaint.
///
/// Screen capture requires the Screen Recording permission; the first stream start
/// triggers the system prompt. Until granted, streams simply produce no frames.
@MainActor
final class ScreenCaptureManager: NSObject {

    /// Latest captured frame per display (nil until the first frame arrives).
    private(set) var frames: [CGDirectDisplayID: CGImage] = [:]

    /// Called (main actor) after any display's frame updates, coalesced by the caller's
    /// redraw. Kept lightweight — just marks the canvas dirty.
    var onFrame: (() -> Void)?

    private var streams: [CGDirectDisplayID: SCStream] = [:]
    private var outputs: [CGDirectDisplayID: FrameOutput] = [:]

    /// The live streams, readable off the main actor — for the feed-guard watchdog:
    /// if capture load wedges the main thread, the watchdog stops these directly
    /// (`SCStream.stopCapture` is safe to call from any thread).
    nonisolated var watchdogStreams: [SCStream] { streamBox.get() }
    private nonisolated let streamBox = LockedStreams()
    private let ciContext = CIContext(options: nil)
    /// Tiles are small; capture at a modest size and frame rate to keep this cheap.
    private let captureHeight = 400
    private let fps = 30

    /// Begin capturing every display, excluding this app's windows. Safe to call again
    /// (e.g. on a display reconfiguration) — it tears down and rebuilds.
    func start() {
        stop()
        Task { await startStreams() }
    }

    /// A quick system-wide CPU busy fraction (0…1) over a brief sampling window, for
    /// deciding whether the live feed should default on. `nil` if it can't be read.
    static func systemCPUUsage() -> Double? {
        func ticks() -> (busy: UInt64, total: UInt64)? {
            // HOST_CPU_LOAD_INFO_COUNT isn't exposed to Swift; derive it from the struct.
            var count = mach_msg_type_number_t(
                MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
            var info = host_cpu_load_info()
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return nil }
            let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
            let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
            let busy = user + system + nice
            return (busy, busy + idle)
        }
        guard let a = ticks() else { return nil }
        usleep(120_000)   // ~120ms sampling window
        guard let b = ticks() else { return nil }
        let dBusy = Double(b.busy &- a.busy), dTotal = Double(b.total &- a.total)
        return dTotal > 0 ? dBusy / dTotal : nil
    }

    func stop() {
        for stream in streams.values {
            stream.stopCapture { _ in }
        }
        streams.removeAll()
        outputs.removeAll()
        streamBox.set([])
    }

    private func startStreams() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true) else { return }

        // Exclude *this whole app* — every Screen Queen overlay on every screen — so the
        // tiles show the real desktop, not our own dim overlay captured recursively.
        // (Excluding individual windows is fragile: a backdrop/glass window mid-
        // registration slips through and each screen captures the others' overlays.)
        let myPID = ProcessInfo.processInfo.processIdentifier
        let myApps = content.applications.filter { $0.processID == myPID }

        for display in content.displays {
            let filter = SCContentFilter(display: display,
                                         excludingApplications: myApps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let scale = Double(captureHeight) / Double(display.height)
            config.width = Int(Double(display.width) * scale)
            config.height = captureHeight
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            config.queueDepth = 3
            config.showsCursor = false

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            let output = FrameOutput(displayID: display.displayID, manager: self)
            do {
                try stream.addStreamOutput(output, type: .screen,
                                           sampleHandlerQueue: .global(qos: .userInitiated))
                try await stream.startCapture()
                streams[display.displayID] = stream
                outputs[display.displayID] = output
            } catch {
                // Permission not yet granted, or the display went away mid-start — skip it.
            }
        }
        streamBox.set(Array(streams.values))
    }

    /// Called off the main actor by a stream output; converts and stores the frame.
    nonisolated fileprivate func ingest(_ sampleBuffer: CMSampleBuffer, for id: CGDirectDisplayID) {
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        Task { @MainActor in
            self.frames[id] = cg
            self.onFrame?()
        }
    }
}

/// A lock around the stream list so the feed-guard watchdog can read it off-main.
private final class LockedStreams: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [SCStream] = []
    func get() -> [SCStream] { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: [SCStream]) { lock.lock(); defer { lock.unlock() }; value = new }
}

/// Per-display stream output: forwards screen frames to the manager.
private final class FrameOutput: NSObject, SCStreamOutput {
    let displayID: CGDirectDisplayID
    weak var manager: ScreenCaptureManager?

    init(displayID: CGDirectDisplayID, manager: ScreenCaptureManager) {
        self.displayID = displayID
        self.manager = manager
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        manager?.ingest(sampleBuffer, for: displayID)
    }
}
