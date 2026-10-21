//
//  WindowCapture.swift
//  boringNotch
//
//  An app's main window for demiffy.com/mac's live view: found once, then
//  streamed. ScreenCaptureKit captures a window even when other windows cover it.
//

import AppKit
import CoreImage
import ScreenCaptureKit

enum WindowCapture {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// The app's largest normal window. Listing every window is the expensive
    /// part, so callers reuse the result for a few frames.
    nonisolated static func findWindow(bundleID: String) async throws -> SCWindow {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let windows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == bundleID && $0.windowLayer == 0 && $0.frame.width > 120 && $0.frame.height > 80
        }
        // Prefer what's actually on screen (a minimised window can't be captured).
        guard let window = windows.max(by: { score($0) < score($1) }) else {
            throw Failure(errorDescription: "No open window")
        }
        return window
    }

    private nonisolated static func score(_ window: SCWindow) -> CGFloat {
        window.frame.width * window.frame.height * (window.isOnScreen ? 10 : 1)
    }
}

/// Streams one window as JPEGs. macOS only hands over a frame when the window
/// actually changed (at most 12 a second), so a still window costs nothing and
/// a scrolling one keeps up — far cheaper and quicker than a screenshot per frame.
final class WindowStream: NSObject, SCStreamOutput, @unchecked Sendable {
    private var stream: SCStream?
    private var size: CGSize = .zero
    private let queue = DispatchQueue(label: "boringNotch.windowStream", qos: .userInitiated)
    private let context = CIContext()
    private let onFrame: @Sendable (Data) -> Void

    init(onFrame: @escaping @Sendable (Data) -> Void) {
        self.onFrame = onFrame
    }

    func start(_ window: SCWindow) async throws {
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: Self.configuration(for: window), delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        size = window.frame.size
    }

    /// Follows a resized window (otherwise its picture would be squashed).
    func follow(_ window: SCWindow) async {
        guard window.frame.size != size, let stream else { return }
        size = window.frame.size
        try? await stream.updateConfiguration(Self.configuration(for: window))
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    /// At most 1280 px wide: plenty for a phone, small enough to send several a second.
    private static func configuration(for window: SCWindow) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let scale = min(2, 1280 / max(window.frame.width, 1))
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 12)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.queueDepth = 3
        return configuration
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let rawStatus = info[.status] as? Int, SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixels = sampleBuffer.imageBuffer else { return }
        let image = CIImage(cvPixelBuffer: pixels)
        // JPEG has no transparency; the rounded corners would come out white.
        let opaque = image.composited(over: CIImage(color: .black).cropped(to: image.extent))
        guard let jpeg = context.jpegRepresentation(
            of: opaque,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.5]
        ) else { return }
        onFrame(jpeg)
    }
}
