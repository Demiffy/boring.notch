//
//  WindowCapture.swift
//  boringNotch
//
//  One picture of an app's main window for demiffy.com/mac's live view.
//  ScreenCaptureKit captures a window even when other windows cover it.
//

import AppKit
import ScreenCaptureKit

enum WindowCapture {
    struct Frame {
        let jpeg: Data
        let title: String?
        /// Global, top-left origin: where clicks from the website land.
        let windowFrame: CGRect
        let pid: pid_t?
    }

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

    /// One picture of the window, at most 1600 px wide (Retina sharp for small windows), as a JPEG.
    nonisolated static func capture(_ window: SCWindow) async throws -> Frame {
        let configuration = SCStreamConfiguration()
        let scale = min(2, 1600 / window.frame.width)
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window),
            configuration: configuration
        )
        guard let jpeg = opaqueJPEG(image) else { throw Failure(errorDescription: "Couldn't encode the picture") }
        return Frame(jpeg: jpeg, title: window.title, windowFrame: window.frame, pid: window.owningApplication?.processID)
    }

    /// JPEG has no transparency; the window's rounded corners came out white.
    /// Drawing onto black first makes them match the viewer's background.
    private nonisolated static func opaqueJPEG(_ image: CGImage) -> Data? {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        guard let opaque = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: opaque).representation(using: .jpeg, properties: [.compressionFactor: 0.6])
    }

    private nonisolated static func score(_ window: SCWindow) -> CGFloat {
        window.frame.width * window.frame.height * (window.isOnScreen ? 10 : 1)
    }
}
