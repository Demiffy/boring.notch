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
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// The app's largest normal window, scaled to at most 1440 px wide, as a JPEG.
    nonisolated static func capture(bundleID: String) async throws -> Frame {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let windows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == bundleID && $0.windowLayer == 0 && $0.frame.width > 120 && $0.frame.height > 80
        }
        // Prefer what's actually on screen (a minimised window can't be captured).
        guard let window = windows.max(by: { score($0) < score($1) }) else {
            throw Failure(errorDescription: "No open window")
        }
        let configuration = SCStreamConfiguration()
        let scale = min(1, 1440 / window.frame.width) * 2
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window),
            configuration: configuration
        )
        guard let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else {
            throw Failure(errorDescription: "Couldn't encode the picture")
        }
        return Frame(jpeg: jpeg, title: window.title)
    }

    private nonisolated static func score(_ window: SCWindow) -> CGFloat {
        window.frame.width * window.frame.height * (window.isOnScreen ? 10 : 1)
    }
}
