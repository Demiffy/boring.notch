//
//  BoringNotchXPCHelper.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import AppKit
import ApplicationServices
import CoreWLAN
import IOKit

class BoringNotchXPCHelper: NSObject, BoringNotchXPCHelperProtocol {
    private weak var connection: NSXPCConnection?

    private let lunarStateQueue = DispatchQueue(label: "BoringNotchXPCHelper.lunar.state")
    private let lunarExecutableURL = URL(fileURLWithPath: "/Applications/Lunar.app/Contents/MacOS/Lunar")
    private var lunarProcess: Process?
    private var lunarPipeHandler: JSONLinesPipeHandler?
    private var lunarStreamTask: Task<Void, Never>?
    private var lunarListener: BoringNotchXPCHelperLunarListener?

    init(connection: NSXPCConnection) {
        self.connection = connection
        super.init()
    }

    override init() {
        super.init()
    }

    deinit {
        var processToTerminate: Process?
        var taskToCancel: Task<Void, Never>?
        var pipeHandlerToClose: JSONLinesPipeHandler?

        lunarStateQueue.sync {
            processToTerminate = self.lunarProcess
            self.lunarProcess = nil

            taskToCancel = self.lunarStreamTask
            self.lunarStreamTask = nil

            pipeHandlerToClose = self.lunarPipeHandler
            self.lunarPipeHandler = nil

            self.lunarListener = nil
        }

        taskToCancel?.cancel()
        if let p = processToTerminate, p.isRunning { p.terminate() }
        if let ph = pipeHandlerToClose {
            Task { await ph.close() }
        }
    }

    @objc func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void) {
        reply(AXIsProcessTrusted())
    }

    /// Moves the pointer to (x, y) and straight back in two posted events —
    /// too fast to see. Lives here because the sandboxed app can't post
    /// events. Coordinates are global, top-left origin.
    @objc func nudgeCursor(throughX x: Double, y: Double) {
        guard AXIsProcessTrusted(), let here = CGEvent(source: nil)?.location else { return }
        for point in [CGPoint(x: x, y: y), here] {
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }

    @objc func migrateLegacyAppBundle(
        from sourcePath: String,
        to destinationPath: String,
        with reply: @escaping (Bool) -> Void
    ) {
        let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
        let destinationURL = URL(fileURLWithPath: destinationPath).standardizedFileURL
        let fileManager = FileManager.default

        guard sourceURL.lastPathComponent == BoringNotchAppBundleNames.legacy,
              destinationURL.lastPathComponent == BoringNotchAppBundleNames.current,
              sourceURL.deletingLastPathComponent() == destinationURL.deletingLastPathComponent(),
              fileManager.fileExists(atPath: sourceURL.path),
              !fileManager.fileExists(atPath: destinationURL.path)
        else {
            NSLog("[boringNotch] refused legacy bundle migration for %@ -> %@", sourcePath, destinationPath)
            reply(false)
            return
        }

        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            NSWorkspace.shared.noteFileSystemChanged(destinationURL.deletingLastPathComponent().path)
            reply(true)
        } catch {
            NSLog("[boringNotch] legacy bundle migration failed for %@: %@", sourcePath, error.localizedDescription)
            reply(false)
        }
    }

    @objc func requestAccessibilityAuthorization() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    @objc func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void) {
        if AXIsProcessTrusted() {
            reply(true)
            return
        }

        guard promptIfNeeded else {
            reply(false)
            return
        }

        requestAccessibilityAuthorization()

        let deadline = DispatchTime.now() + .seconds(15)
        func waitForAuthorization() {
            if AXIsProcessTrusted() {
                reply(true)
            } else if DispatchTime.now() >= deadline {
                reply(false)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    waitForAuthorization()
                }
            }
        }
        waitForAuthorization()
    }

    // MARK: - Notification Center banners

    private static let watcher = NotificationWatcher()

    @objc func startNotificationWatching(with reply: @escaping (Bool) -> Void) {
        // Capture the delegate for this connection before hopping queues —
        // NSXPCConnection.current() is only valid inside the incoming call.
        //
        // Cast to BoringNotchXPCAppDelegate, not its parent protocol: the
        // proxy's conformance is built from the exact interface the
        // connection was configured with, so casting to the parent can
        // return nil and silently swallow every callback.
        let connection = NSXPCConnection.current()
        let proxy = connection?.remoteObjectProxyWithErrorHandler { error in
            NSLog("[boringNotch] notification callback failed: \(error.localizedDescription)")
        }
        let delegate = proxy as? BoringNotchXPCAppDelegate

        if delegate == nil {
            NSLog("[boringNotch] could not obtain notification delegate proxy — banners will not reach the app")
        }

        DispatchQueue.main.async {
            let watcher = Self.watcher
            watcher.onBanner = { notification in
                delegate?.notificationDidAppear([
                    "token": notification.token,
                    "appName": notification.appName ?? "",
                    "bundleID": notification.bundleID ?? "",
                    "title": notification.title ?? "",
                    "subtitle": notification.subtitle ?? "",
                    "body": notification.body ?? "",
                    "iconRect": notification.iconRect.map { NSStringFromRect(NSRectFromCGRect($0)) } ?? ""
                ])
            }
            let started = watcher.start()
            NSLog("[boringNotch] notification watcher start -> \(started), AX trusted: \(AXIsProcessTrusted())")
            reply(started)
        }
    }

    @objc func stopNotificationWatching() {
        DispatchQueue.main.async { Self.watcher.stop() }
    }

    @objc func notificationIconRect(token: String, with reply: @escaping (String) -> Void) {
        DispatchQueue.main.async {
            reply(Self.watcher.iconRect(token: token).map { NSStringFromRect(NSRectFromCGRect($0)) } ?? "")
        }
    }

    @objc func setKeepNotificationBanners(_ keep: Bool) {
        DispatchQueue.main.async { Self.watcher.keepBanners = keep }
    }

    @objc func openNotification(token: String, with reply: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            reply(Self.watcher.open(token: token))
        }
    }

    // MARK: - Search my Mac (demiffy.com)

    private static let maxUploadBytes = 95 * 1024 * 1024
    private static let maxSearchResults = 50

    /// The home folder minus what's private: Library (app data, mail,
    /// keychains), anything hidden (.ssh, .config, …) and the Trash.
    static func isSearchable(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        let standardized = (path as NSString).standardizingPath
        guard standardized.hasPrefix(home + "/") else { return false }
        let parts = standardized.dropFirst(home.count + 1).split(separator: "/")
        guard let first = parts.first, first != "Library" else { return false }
        return !parts.contains { $0.hasPrefix(".") }
    }

    /// Spotlight over the home folder: filename matches first, then files
    /// whose contents match, newest first within each.
    @objc func searchFiles(query: String, with reply: @escaping ([[String: Any]]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let home = NSHomeDirectory()
            let byName = Self.mdfind(["-onlyin", home, "-name", query])
            let byContent = Self.mdfind(["-onlyin", home, query])
            var seen = Set<String>()
            var groups: [[[String: Any]]] = [[], []]
            for (group, paths) in [byName, byContent].enumerated() {
                for path in paths where seen.insert(path).inserted && Self.isSearchable(path) {
                    if let entry = Self.describe(path) { groups[group].append(entry) }
                    if groups[0].count + groups[1].count >= Self.maxSearchResults * 2 { break }
                }
            }
            let newestFirst: ([String: Any], [String: Any]) -> Bool = {
                ($0["modifiedAt"] as? String ?? "") > ($1["modifiedAt"] as? String ?? "")
            }
            reply(Array((groups[0].sorted(by: newestFirst) + groups[1].sorted(by: newestFirst)).prefix(Self.maxSearchResults)))
        }
    }

    /// Opens a file for the app to upload. The sandboxed app can't read
    /// arbitrary paths, but it can read from a handle passed over XPC.
    @objc func openFileForUpload(path: String, with reply: @escaping (FileHandle?, String?) -> Void) {
        guard Self.isSearchable(path) else { return reply(nil, "That file isn't in a searchable folder") }
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { return reply(nil, "Not a file") }
        guard (values?.fileSize ?? 0) <= Self.maxUploadBytes else { return reply(nil, "Over 95 MB — too big to send") }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return reply(nil, "Couldn't open the file") }
        reply(handle, nil)
    }

    @objc func systemExtras(with reply: @escaping ([String: Any]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var extras: [String: Any] = ["processes": Self.topProcesses()]
            if let battery = Self.batteryDetails() { extras["battery"] = battery }
            if let wifi = CWWiFiClient.shared().interface(), wifi.powerOn() {
                var info: [String: Any] = ["rssi": wifi.rssiValue(), "noise": wifi.noiseMeasurement(), "txRate": wifi.transmitRate()]
                // Nil unless the helper has Location access; shown when present.
                if let ssid = wifi.ssid() { info["ssid"] = ssid }
                extras["wifi"] = info
            }
            reply(extras)
        }
    }

    /// The five busiest processes by CPU, as Activity Monitor would list them.
    private static func topProcesses() -> [[String: Any]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Aceo", "pcpu=,rss=,comm=", "-r"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output.split(separator: "\n").prefix(5).compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let cpu = Double(parts[0]), let rssKB = Double(parts[1]) else { return nil }
            return ["name": String(parts[2]), "cpu": cpu, "memoryBytes": rssKB * 1024]
        }
    }

    /// Health (capacity now vs. new), cycles, power draw and time left, from the battery's own registry entry.
    private static func batteryDetails() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }
        var details: [String: Any] = [:]
        if let cycles = props["CycleCount"] as? Int { details["cycles"] = cycles }
        let data = props["BatteryData"] as? [String: Any]
        if let nominal = data?["NominalChargeCapacity"] as? Double, let design = data?["DesignCapacity"] as? Double, design > 0 {
            details["healthPercent"] = min(100, nominal / design * 100)
        }
        // Amperage (mA) is signed but may come back as a huge unsigned number;
        // int64Value reads it either way. Negative means discharging.
        if let volts = (props["Voltage"] as? NSNumber)?.doubleValue, let amps = (props["InstantAmperage"] as? NSNumber)?.int64Value {
            details["watts"] = abs(Double(amps)) / 1000 * volts / 1000
        }
        if let minutes = props["TimeRemaining"] as? Int, minutes > 0, minutes < 65535 { details["minutesLeft"] = minutes }
        return details
    }

    private static func mdfind(_ arguments: [String]) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        // A broad query can list thousands of files; stop waiting after 4 s.
        let deadline = DispatchTime.now() + 4
        DispatchQueue.global().asyncAfter(deadline: deadline) { if process.isRunning { process.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(2000).map(String.init)
    }

    private static func describe(_ path: String) -> [String: Any]? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey, .isPackageKey]) else { return nil }
        let isFolder = values.isDirectory == true && values.isPackage != true
        var entry: [String: Any] = [
            "name": url.lastPathComponent,
            "path": path,
            "isFolder": isFolder,
            "kind": values.localizedTypeDescription ?? "",
        ]
        if let size = values.fileSize { entry["size"] = size }
        if let date = values.contentModificationDate { entry["modifiedAt"] = ISO8601DateFormatter().string(from: date) }
        return entry
    }

    // MARK: - Remote input (demiffy.com live view)

    /// Brings the window to the front, then posts each event at its spot.
    /// Clicks and scrolls put the pointer back where it was afterwards, so
    /// someone at the Mac only sees it jump for a moment.
    @objc func postWindowInput(_ events: [[String: Any]], pid: Int32, windowFrame: [Double], with reply: @escaping (String?) -> Void) {
        guard AXIsProcessTrusted() else { return reply("The notch's helper doesn't have Accessibility access") }
        guard windowFrame.count == 4, NSRunningApplication(processIdentifier: pid) != nil else { return reply("The window is gone") }
        let frame = CGRect(x: windowFrame[0], y: windowFrame[1], width: windowFrame[2], height: windowFrame[3])
        DispatchQueue.global(qos: .userInteractive).async {
            if Self.bringToFront(pid: pid, frame: frame) { usleep(150_000) }
            for event in events { Self.post(event, in: frame) }
            reply(nil)
        }
    }

    /// Returns true when something had to move (the caller waits for it).
    private static func bringToFront(pid: pid_t, frame: CGRect) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var frontmost: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXFrontmostAttribute as CFString, &frontmost)
        var windowsValue: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue)
        let windows = windowsValue as? [AXUIElement] ?? []
        let target = windows.first { window in
            var position = CGPoint.zero, size = CGSize.zero
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success, let value {
                AXValueGetValue(value as! AXValue, .cgPoint, &position)
            }
            if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &value) == .success, let value {
                AXValueGetValue(value as! AXValue, .cgSize, &size)
            }
            return abs(position.x - frame.minX) < 4 && abs(position.y - frame.minY) < 4
                && abs(size.width - frame.width) < 4 && abs(size.height - frame.height) < 4
        }
        var mainValue: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &mainValue)
        let alreadyFront = (frontmost as? Bool) == true && target.map { CFEqual($0, mainValue) } != false
        guard !alreadyFront else { return false }
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let target { AXUIElementPerformAction(target, kAXRaiseAction as CFString) }
        return true
    }

    private static func post(_ event: [String: Any], in frame: CGRect) {
        let point = CGPoint(
            x: frame.minX + (event["x"] as? Double ?? 0.5) * frame.width,
            y: frame.minY + (event["y"] as? Double ?? 0.5) * frame.height
        )
        switch event["type"] as? String {
        case "click":
            let right = event["button"] as? String == "right"
            let back = CGEvent(source: nil)?.location
            let count = Int64(event["count"] as? Int ?? 1)
            for type: CGEventType in right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp] {
                let mouse = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: right ? .right : .left)
                mouse?.setIntegerValueField(.mouseEventClickState, value: count)
                mouse?.post(tap: .cghidEventTap)
            }
            if let back, count == 1, !right { usleep(30_000); CGWarpMouseCursorPosition(back) }
        case "scroll":
            let back = CGEvent(source: nil)?.location
            CGWarpMouseCursorPosition(point)
            let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                 wheel1: Int32(-(event["dy"] as? Double ?? 0)), wheel2: Int32(-(event["dx"] as? Double ?? 0)), wheel3: 0)
            scroll?.location = point
            scroll?.post(tap: .cghidEventTap)
            if let back { usleep(30_000); CGWarpMouseCursorPosition(back) }
        case "text":
            for character in (event["text"] as? String ?? "") {
                let units = Array(String(character).utf16)
                for down in [true, false] {
                    let key = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                    key?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    key?.post(tap: .cghidEventTap)
                }
            }
        case "key":
            guard let name = event["key"] as? String, let code = keyCodes[name] else { return }
            var flags: CGEventFlags = []
            for modifier in event["mods"] as? [String] ?? [] {
                switch modifier {
                case "cmd": flags.insert(.maskCommand)
                case "shift": flags.insert(.maskShift)
                case "alt": flags.insert(.maskAlternate)
                case "ctrl": flags.insert(.maskControl)
                default: break
                }
            }
            let units = name.count == 1 ? Array(name.utf16) : []
            for down in [true, false] {
                let key = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
                key?.flags = flags
                if !units.isEmpty { key?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units) }
                key?.post(tap: .cghidEventTap)
            }
        default:
            break
        }
    }

    /// ANSI key positions; letters and digits are only used with modifiers (shortcuts).
    private static let keyCodes: [String: CGKeyCode] = {
        var codes: [String: CGKeyCode] = [
            "Enter": 36, "Tab": 48, " ": 49, "Backspace": 51, "Escape": 53, "Delete": 117,
            "Home": 115, "End": 119, "PageUp": 116, "PageDown": 121,
            "ArrowLeft": 123, "ArrowRight": 124, "ArrowDown": 125, "ArrowUp": 126,
        ]
        let layout: [(String, CGKeyCode)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
            ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("1", 18), ("2", 19),
            ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("=", 24), ("9", 25), ("7", 26), ("-", 27), ("8", 28),
            ("0", 29), ("]", 30), ("o", 31), ("u", 32), ("[", 33), ("i", 34), ("p", 35), ("l", 37), ("j", 38),
            ("'", 39), ("k", 40), (";", 41), ("\\", 42), (",", 43), ("/", 44), ("n", 45), ("m", 46), (".", 47), ("`", 50),
        ]
        for (key, code) in layout { codes[key] = code }
        return codes
    }()

    /// Asks an app to quit normally (it can still save or ask first).
    @objc func quitApplication(pid: Int32) {
        DispatchQueue.main.async {
            NSRunningApplication(processIdentifier: pid)?.terminate()
        }
    }

    @objc func setNotificationFilter(_ bundleIDs: [String], allApps: Bool) {
        DispatchQueue.main.async {
            Self.watcher.configureFilter(bundleIDs: Set(bundleIDs), allApps: allApps)
        }
    }
    private class KeyboardBrightnessClient {
        private static let keyboardID: UInt64 = 1
        private var clientInstance: NSObject?
        private let getSelector = NSSelectorFromString("brightnessForKeyboard:")
        private let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")

        init() {
            var loaded = false
            let bundlePaths = [
                "/System/Library/PrivateFrameworks/CoreBrightness.framework",
                "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
            ]
            for path in bundlePaths where !loaded {
                if let bundle = Bundle(path: path) {
                    loaded = bundle.load()
                }
            }
            if loaded, let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
                clientInstance = cls.init()
            }
        }

        func currentBrightness() -> Float? {
            guard let clientInstance,
                  let fn: BrightnessGetter = methodIMP(on: clientInstance, selector: getSelector, as: BrightnessGetter.self)
            else { return nil }
            return fn(clientInstance, getSelector, Self.keyboardID)
        }

        func setBrightness(_ value: Float) -> Bool {
            guard let clientInstance,
                  let fn: BrightnessSetter = methodIMP(on: clientInstance, selector: setSelector, as: BrightnessSetter.self)
            else { return false }
            return fn(clientInstance, setSelector, value, Self.keyboardID).boolValue
        }

        private typealias BrightnessGetter = @convention(c) (NSObject, Selector, UInt64) -> Float
        private typealias BrightnessSetter = @convention(c) (NSObject, Selector, Float, UInt64) -> ObjCBool

        private func methodIMP<T>(on object: NSObject, selector: Selector, as type: T.Type) -> T? {
            guard let cls = object_getClass(object),
                  let method = class_getInstanceMethod(cls, selector)
            else { return nil }
            let imp = method_getImplementation(method)
            return unsafeBitCast(imp, to: type)
        }
    }

    private static let keyboardClient = KeyboardBrightnessClient()

    @objc func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void) {
        reply(Self.keyboardClient.currentBrightness().map { NSNumber(value: $0) })
    }

    @objc func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.setBrightness(value))
    }
    // MARK: - Screen Brightness (moved from client app into helper)

    private func brightnessDisplayID() -> CGDirectDisplayID {
        let mainDisplayID = CGMainDisplayID()
        var tmp: Float = 0

        if displayServicesGetBrightness(displayID: mainDisplayID, out: &tmp) || ioServiceFor(displayID: mainDisplayID) != nil {
            return mainDisplayID
        }

        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        let allocated = Int(count)
        var ids = [CGDirectDisplayID](repeating: 0, count: allocated)
        CGGetOnlineDisplayList(count, &ids, &count)
        for id in ids {
            if CGDisplayIsBuiltin(id) != 0 {
                return id
            }
        }

        return mainDisplayID
    }

    @objc func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void) {
        let displayID = brightnessDisplayID()
        var b: Float = 0
        if displayServicesGetBrightness(displayID: displayID, out: &b) {
            reply(NSNumber(value: b))
            return
        }
        if let io = ioServiceFor(displayID: displayID) {
            var level: Float = 0
            if IODisplayGetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, &level) == kIOReturnSuccess {
                IOObjectRelease(io)
                reply(NSNumber(value: level))
                return
            }
            IOObjectRelease(io)
        }
        reply(nil)
    }

    @objc func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        let clamped = max(0, min(1, value))
        let displayID = brightnessDisplayID()
        if displayServicesSetBrightness(displayID: displayID, value: clamped) {
            reply(true)
            return
        }
        if let io = ioServiceFor(displayID: displayID) {
            let ok = IODisplaySetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, clamped) == kIOReturnSuccess
            IOObjectRelease(io)
            reply(ok)
            return
        }
        reply(false)
    }

    @objc func adjustScreenBrightness(by value: Float, with reply: @escaping (NSNumber?) -> Void) {
        let displayID = brightnessDisplayID()
        if displayServicesSetBrightnessSmooth(displayID: displayID, value: value) {
            // Read back inside the helper so the client pays for one RPC
            // instead of two (adjust + currentScreenBrightness).
            var b: Float = 0
            if displayServicesGetBrightness(displayID: displayID, out: &b) {
                reply(NSNumber(value: b))
                return
            }
            reply(nil)
            return
        }
        if let io = ioServiceFor(displayID: displayID) {
            var ioCurrent: Float = 0
            if IODisplayGetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, &ioCurrent) == kIOReturnSuccess {
                let target = max(0, min(1, ioCurrent + value))
                let ok = IODisplaySetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, target) == kIOReturnSuccess
                IOObjectRelease(io)
                reply(ok ? NSNumber(value: target) : nil)
                return
            }
            IOObjectRelease(io)
        }
        reply(nil)
    }

    // MARK: - Lunar Events

    @objc func displayIDForBrightness(with reply: @escaping (NSNumber?) -> Void) {
        let id = brightnessDisplayID()
        reply(NSNumber(value: id))
    }

    @objc func isLunarAvailable(with reply: @escaping (Bool) -> Void) {
        reply(FileManager.default.isExecutableFile(atPath: lunarExecutableURL.path))
    }

    @objc func startLunarEventStream(with reply: @escaping (Bool) -> Void) {
        lunarStateQueue.async { [weak self] in
            guard let self else {
                reply(false)
                return
            }

            if let lunarProcess = self.lunarProcess, lunarProcess.isRunning {
                reply(true)
                return
            }

            guard FileManager.default.isExecutableFile(atPath: self.lunarExecutableURL.path) else {
                reply(false)
                return
            }

            guard let connection = self.connection else {
                reply(false)
                return
            }

            let listenerProxy = connection.remoteObjectProxyWithErrorHandler { _ in
                self.stopLunarEventStream()
            } as? BoringNotchXPCHelperLunarListener

            guard let listenerProxy else {
                reply(false)
                return
            }

            let process = Process()
            process.executableURL = self.lunarExecutableURL
            process.arguments = ["@", "listen", "--only-user-adjustments", "-j"]

            let pipeHandler = JSONLinesPipeHandler()
            process.standardOutput = pipeHandler.outputPipe
            process.standardError = FileHandle.nullDevice

            process.terminationHandler = { [weak self] _ in
                self?.stopLunarEventStream(reason: "Lunar stream ended")
            }

            do {
                try process.run()
            } catch {
                reply(false)
                return
            }

            self.lunarProcess = process
            self.lunarPipeHandler = pipeHandler
            self.lunarListener = listenerProxy

            let currentPipeHandler = pipeHandler
            self.lunarStreamTask = Task { [weak self] in
                await self?.readLunarEvents(pipeHandler: currentPipeHandler)
            }

            reply(true)
        }
    }

    @objc func stopLunarEventStream() {
        stopLunarEventStream(reason: nil)
    }

    private func stopLunarEventStream(reason: String?) {
        lunarStateQueue.async { [weak self] in
            guard let self else { return }

            self.lunarStreamTask?.cancel()
            self.lunarStreamTask = nil

            if let lunarProcess = self.lunarProcess, lunarProcess.isRunning {
                lunarProcess.terminate()
            }

            self.lunarProcess = nil

            if let pipeHandler = self.lunarPipeHandler {
                pipeHandler.close()
            }

            self.lunarPipeHandler = nil

            if let reason {
                self.lunarListener?.lunarStreamDidStop(reason)
            }

            self.lunarListener = nil
        }
    }

    private func readLunarEvents(pipeHandler: JSONLinesPipeHandler) async {
        await pipeHandler.readJSONLines(as: LunarBrightnessEvent.self) { [weak self] event in
            self?.emitLunarEvent(event)
        }
    }

    private func emitLunarEvent(_ event: LunarBrightnessEvent) {
        let payload = BNLunarBrightnessEvent(
            brightness: event.brightness,
            display: event.display
        )
        lunarStateQueue.async { [weak self] in
            self?.lunarListener?.lunarEventDidUpdate(payload)
        }
    }

    // MARK: - Lunar OSD preference (hideOSD)

    private static let lunarBundleID = "fyi.lunar.Lunar"
    private static let lunarHideOSDKey = "hideOSD"

    @objc func setLunarOSDHidden(_ hide: Bool, with reply: @escaping (Bool) -> Void) {
        let appID = Self.lunarBundleID as CFString
        let key = Self.lunarHideOSDKey as CFString
        let value = hide as CFBoolean
        NSLog("Hide OSD in Lunar: \(hide)")
        CFPreferencesSetValue(key, value, appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let ok = CFPreferencesSynchronize(appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        reply(ok)
    }

    // MARK: - Private helpers for DisplayServices / IOKit access
    private func displayServicesGetBrightness(displayID: CGDirectDisplayID, out: inout Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesGetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        var tmp: Float = 0
        let r = fn(displayID, &tmp)
        if r == 0 { out = tmp; return true }
        return false
    }

    private func displayServicesSetBrightness(displayID: CGDirectDisplayID, value: Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesSetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(displayID, value) == 0
    }

    private func displayServicesSetBrightnessSmooth(displayID: CGDirectDisplayID, value: Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesSetBrightnessSmooth") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(displayID, value) == 0
    }

    private func ioServiceFor(displayID: CGDirectDisplayID) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            let info = IODisplayCreateInfoDictionary(service, 0).takeRetainedValue() as NSDictionary
            if let vendorID = info[kDisplayVendorID] as? UInt32,
               let productID = info[kDisplayProductID] as? UInt32,
               vendorID == CGDisplayVendorNumber(displayID),
               productID == CGDisplayModelNumber(displayID) {
                return service
            }
            IOObjectRelease(service)
        }
        return nil
    }

    // MARK: - Helper handle for private framework
    private enum DisplayServicesHandle {
        static let handle: UnsafeMutableRawPointer? = {
            let paths = [
                "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/Current/DisplayServices"
            ]
            for p in paths {
                if let h = dlopen(p, RTLD_LAZY) { return h }
            }
            return nil
        }()
    }
}

// MARK: - Lunar Parsing

private struct LunarBrightnessEvent: Decodable, Sendable {
    let brightness: Double
    let display: Int
}
