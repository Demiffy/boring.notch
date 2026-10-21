//
//  MacReporter.swift
//  boringNotch
//
//  Reports this Mac to demiffy.com (/mac) and runs the safe commands the site
//  sends back: a message in the notch, play/pause, a find-my-Mac sound, lock.
//  Reports go out every minute, every few seconds while the page is open, and
//  shortly after anything worth showing changes; commands arrive over one long-poll, so they land in about a second.
//

import AppKit
import Combine
import Defaults
import ScreenCaptureKit

@MainActor
final class MacReporter {
    static let shared = MacReporter()

    private let client = DemiffyClient.shared
    private var reportTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var pendingReport: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()

    private var isLocked = false
    private var lastCPUTicks: (used: UInt64, total: UInt64)?
    private var lastNetwork: (at: Date, counters: [String: (rx: UInt32, tx: UInt32)])?
    /// Someone has the Mac page open; the server says so in its reply.
    private var live = false
    private var uploadedIcons = Set<String>()
    private var viewTask: Task<Void, Never>?
    private var currentViewID: String?
    /// Where the viewed window was in the latest frame; website clicks map onto it.
    private var viewedWindow: (frame: CGRect, pid: pid_t)?
    private var lastInputAt = Date.distantPast
    private var inputProblem: (message: String, at: Date)?

    private init() {}

    func start() {
        guard reportTask == nil else { return }
        reportTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.report()
                try? await Task.sleep(for: .seconds(self?.live == true ? 5 : 60))
            }
        }
        pollTask = Task { [weak self] in await self?.pollLoop() }
        observe()
    }

    func stop() {
        reportTask?.cancel()
        pollTask?.cancel()
        pendingReport?.cancel()
        reportTask = nil
        pollTask = nil
        observers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
            DistributedNotificationCenter.default().removeObserver($0)
        }
        observers.removeAll()
        cancellables.removeAll()
    }

    // MARK: - Triggers

    private func observe() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await MacReporter.shared.report(sleeping: true) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in MacReporter.shared.reportSoon() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in MacReporter.shared.reportSoon(after: 5) }
        })
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            Task { @MainActor in
                MacReporter.shared.isLocked = true
                MacReporter.shared.reportSoon()
            }
        })
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            Task { @MainActor in
                MacReporter.shared.isLocked = false
                MacReporter.shared.reportSoon()
            }
        })

        let music = MusicManager.shared
        music.$songTitle.removeDuplicates().dropFirst()
            .merge(with: music.$isPlaying.removeDuplicates().dropFirst().map { _ in "" })
            .sink { _ in Task { @MainActor in MacReporter.shared.reportSoon() } }
            .store(in: &cancellables)
        BatteryStatusViewModel.shared.$isPluggedIn.removeDuplicates().dropFirst()
            .sink { _ in Task { @MainActor in MacReporter.shared.reportSoon() } }
            .store(in: &cancellables)
    }

    /// Coalesces bursts (a song change fires several updates) into one report.
    private func reportSoon(after seconds: Double = 2) {
        pendingReport?.cancel()
        pendingReport = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.report()
        }
    }

    // MARK: - Report

    private func report(sleeping: Bool = false) async {
        guard client.canCallServer, Defaults[.demiffyReportMac] else { return }
        do {
            let reply = try await client.postJSON("notch/report", body: await snapshot(sleeping: sleeping))
            live = reply["live"] as? Bool ?? false
            if let missing = reply["needIcons"] as? [String] { await uploadIcons(missing) }
        } catch {
            client.noteRejection(error)
        }
    }

    private func snapshot(sleeping: Bool) async -> [String: Any] {
        let battery = BatteryStatusViewModel.shared
        let disk = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        let os = ProcessInfo.processInfo.operatingSystemVersion

        var vitals: [String: Any] = [
            "uptimeS": ProcessInfo.processInfo.systemUptime,
            "osVersion": "\(os.majorVersion).\(os.minorVersion)",
        ]
        if battery.maxCapacity != nil || battery.levelBattery > 0 {
            vitals["battery"] = Double(battery.levelBattery)
            vitals["charging"] = battery.isCharging
            vitals["pluggedIn"] = battery.isPluggedIn
        }
        if let cpu = cpuPercent() { vitals["cpu"] = cpu }
        if let memory = memoryPercent() { vitals["memory"] = memory }
        if let free = disk?.volumeAvailableCapacityForImportantUsage { vitals["diskFreeBytes"] = Double(free) }
        if let total = disk?.volumeTotalCapacity { vitals["diskTotalBytes"] = Double(total) }
        if let model = Self.hardwareModel() { vitals["model"] = model }
        let volume = VolumeManager.shared
        vitals["volume"] = Double(volume.rawVolume) * 100
        vitals["muted"] = volume.isMuted
        BrightnessManager.shared.refresh()
        vitals["brightness"] = Double(BrightnessManager.shared.rawBrightness) * 100
        vitals["thermal"] = ["nominal", "fair", "serious", "critical"][ProcessInfo.processInfo.thermalState.rawValue]

        var body: [String: Any] = ["state": sleeping ? "sleeping" : "awake", "vitals": vitals]
        if !sleeping {
            let extras = await XPCHelperClient.shared.systemExtras()
            var network: [String: Any] = extras["wifi"] as? [String: Any] ?? [:]
            if let rates = networkRates() {
                network["rxBps"] = rates.rx
                network["txBps"] = rates.tx
            }
            body["network"] = network
            if let details = extras["battery"] { body["battery"] = details }
            if Defaults[.demiffyShareActivity], let processes = extras["processes"] { body["processes"] = processes }
        }

        if Defaults[.demiffyShareNowPlaying] {
            let music = MusicManager.shared
            body["nowPlaying"] = music.songTitle.isEmpty ? NSNull() : [
                "title": music.songTitle,
                "artist": music.artistName,
                "album": music.album,
                "app": music.bundleIdentifier.flatMap(Self.appName) ?? "",
                "playing": music.isPlaying,
            ] as [String: Any]
        }
        if Defaults[.demiffyShareActivity] {
            body["activity"] = [
                "frontApp": NSWorkspace.shared.frontmostApplication?.localizedName ?? "",
                "locked": isLocked,
            ] as [String: Any]
            body["apps"] = Self.dockApps().map { app in
                ["name": app.localizedName ?? "", "bundleId": app.bundleIdentifier ?? "", "active": app.isActive] as [String: Any]
            }
        }
        return body
    }

    /// Share of CPU time spent busy since the previous report, across all cores.
    private func cpuPercent() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        let used = UInt64(ticks.0) + UInt64(ticks.1) + UInt64(ticks.3) // user + system + nice
        let total = used + UInt64(ticks.2) // + idle
        defer { lastCPUTicks = (used, total) }
        guard let last = lastCPUTicks, total > last.total else { return nil }
        return Double(used - last.used) / Double(total - last.total) * 100
    }

    /// App memory + wired + compressed, the same "Memory Used" Activity Monitor shows.
    private func memoryPercent() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let appPages = max(0, Int(stats.internal_page_count) - Int(stats.purgeable_count))
        let pages = appPages + Int(stats.wire_count) + Int(stats.compressor_page_count)
        let used = Double(pages) * Double(getpagesize())
        return used / Double(ProcessInfo.processInfo.physicalMemory) * 100
    }

    /// Bytes per second in and out over the Wi-Fi/Ethernet interfaces since
    /// the previous report. The counters are 32-bit, so differences wrap.
    private func networkRates() -> (rx: Double, tx: Double)? {
        var counters: [String: (rx: UInt32, tx: UInt32)] = [:]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var cursor = list
        while let entry = cursor?.pointee {
            cursor = entry.ifa_next
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en"), entry.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.ifa_data?.assumingMemoryBound(to: if_data.self).pointee else { continue }
            counters[name] = (data.ifi_ibytes, data.ifi_obytes)
        }
        let now = Date()
        defer { lastNetwork = (now, counters) }
        guard let last = lastNetwork else { return nil }
        let seconds = now.timeIntervalSince(last.at)
        guard seconds > 0.5 else { return nil }
        var rx: UInt64 = 0, tx: UInt64 = 0
        for (name, value) in counters {
            guard let old = last.counters[name] else { continue }
            rx += UInt64(value.rx &- old.rx)
            tx += UInt64(value.tx &- old.tx)
        }
        return (Double(rx) / seconds, Double(tx) / seconds)
    }

    /// Apps that would show in the Dock, Finder first like the real one.
    private static func dockApps() -> [NSRunningApplication] {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
        return Array((apps.filter { $0.bundleIdentifier == "com.apple.finder" } + apps.filter { $0.bundleIdentifier != "com.apple.finder" }).prefix(24))
    }

    /// Sends the icons the site doesn't have yet, a few at a time, as 64 px PNGs.
    private func uploadIcons(_ bundleIDs: [String]) async {
        let wanted = bundleIDs.filter { !uploadedIcons.contains($0) }
        let apps = Self.dockApps()
        for batch in stride(from: 0, to: wanted.count, by: 5).map({ Array(wanted[$0..<min($0 + 5, wanted.count)]) }) {
            var icons: [[String: String]] = []
            for bundleID in batch {
                uploadedIcons.insert(bundleID)
                guard let icon = apps.first(where: { $0.bundleIdentifier == bundleID })?.icon,
                      let png = Self.png(icon, side: 64) else { continue }
                icons.append(["bundleId": bundleID, "png": png.base64EncodedString()])
            }
            guard !icons.isEmpty else { continue }
            try? await client.postJSON("notch/app-icons", body: ["icons": icons])
        }
    }

    private static func png(_ image: NSImage, side: Int) -> Data? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func hardwareModel() -> String? {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var chars = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &chars, &size, nil, 0)
        return String(cString: chars)
    }

    private static func appName(_ bundleID: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
    }

    // MARK: - Commands

    // MARK: - Search my Mac

    private func answerSearch(searchId: String, query: String) async {
        let results = await XPCHelperClient.shared.searchFiles(query: query)
        try? await client.postJSON("notch/search-results", body: ["searchId": searchId, "results": results])
    }

    /// Sends a file the website picked from a search to Cloud/From Mac, and
    /// says so in the notch — a file leaving the Mac shouldn't go unnoticed.
    private func answerFetch(fetchId: String, path: String) async {
        let name = (path as NSString).lastPathComponent
        do {
            let handle = try await XPCHelperClient.shared.openFileForUpload(path: path)
            let url = try await client.uploadFromMac(handle, named: name)
            try? await client.postJSON("notch/fetch-result", body: ["fetchId": fetchId, "url": url, "name": name])
            SystemNotificationManager.shared.present(SystemNotification(
                id: fetchId,
                appName: "Demiffy",
                bundleID: nil,
                title: "Sent to your Cloud",
                subtitle: nil,
                body: "\(name) was fetched from demiffy.com",
                receivedAt: Date(),
                iconAsset: "DemiffyLogo",
                url: client.siteURL(path: "cloud")
            ))
        } catch {
            try? await client.postJSON("notch/fetch-result", body: ["fetchId": fetchId, "error": error.localizedDescription])
        }
    }

    // MARK: - Live window view

    /// Sends a picture of one app's window about once a second for as long as
    /// the page keeps asking (the server says when nobody watches), ten
    /// minutes at most. Never while locked; the notch shows an eye meanwhile.
    private func startViewing(viewID: String, bundleID: String) {
        viewTask?.cancel()
        currentViewID = viewID
        viewedWindow = nil
        client.viewing = Self.appName(bundleID) ?? bundleID
        viewTask = Task { [weak self] in
            let started = Date()
            var window: (found: SCWindow, at: Date)?
            while let self, !Task.isCancelled, Date().timeIntervalSince(started) < 600 {
                var frame: WindowCapture.Frame?
                var problem: String?
                if !Defaults[.demiffyAllowViewing] {
                    problem = "Viewing is switched off in the notch's Demiffy settings"
                } else if self.isLocked {
                    problem = "The Mac is locked"
                } else {
                    do {
                        // Look the window up again every few seconds (it may move or close).
                        if window == nil || Date().timeIntervalSince(window!.at) > 3 {
                            window = (try await WindowCapture.findWindow(bundleID: bundleID), Date())
                        }
                        frame = try await WindowCapture.capture(window!.found)
                    } catch {
                        window = nil
                        problem = error.localizedDescription
                    }
                }
                if let frame, let pid = frame.pid { self.viewedWindow = (frame.windowFrame, pid) }
                let inputError = self.inputProblem.flatMap { Date().timeIntervalSince($0.at) < 8 ? $0.message : nil }
                let keepGoing = (try? await self.client.postFrame(
                    viewID: viewID, jpeg: frame?.jpeg, title: frame?.title, error: problem, inputError: inputError
                )) ?? false
                guard keepGoing else { break }
                // Quicker frames right after a click or key, so it feels live.
                let interacting = Date().timeIntervalSince(self.lastInputAt) < 10
                try? await Task.sleep(for: .milliseconds(interacting ? 300 : 1000))
            }
            if self?.currentViewID == viewID {
                self?.client.viewing = nil
                self?.currentViewID = nil
            }
        }
    }

    /// Clicks, scrolls and keys from the website, only into the window being
    /// viewed right now, never while locked, and only if allowed in settings.
    private func applyInput(viewID: String, events: [[String: Any]]) async {
        guard viewID == currentViewID else { return }
        let problem: String?
        if !Defaults[.demiffyAllowViewing] || !Defaults[.demiffyAllowControl] {
            problem = "Control is switched off in the notch's Demiffy settings"
        } else if isLocked {
            problem = "The Mac is locked"
        } else if let window = viewedWindow {
            problem = await XPCHelperClient.shared.postWindowInput(events, pid: window.pid, windowFrame: window.frame)
        } else {
            problem = "Wait for the first picture"
        }
        lastInputAt = Date()
        inputProblem = problem.map { ($0, Date()) }
    }

    // MARK: - Clipboard

    private func answerClipboard(requestID: String) async {
        let pasteboard = NSPasteboard.general
        var body: [String: Any] = ["requestId": requestID]
        // Password managers mark what they copy; that never leaves the Mac.
        if pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true {
            body["error"] = "Hidden — a password manager copied it"
        } else if let text = pasteboard.string(forType: .string) {
            body["text"] = String(text.prefix(10_000))
        } else {
            body["error"] = pasteboard.types?.isEmpty == false ? "The clipboard holds something other than text" : "The clipboard is empty"
        }
        try? await client.postJSON("notch/clipboard", body: body)
    }

    private func setClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        SystemNotificationManager.shared.present(SystemNotification(
            id: UUID().uuidString,
            appName: "Demiffy",
            bundleID: nil,
            title: "Copied from demiffy.com",
            subtitle: nil,
            body: String(text.prefix(120)),
            receivedAt: Date(),
            iconAsset: "DemiffyLogo",
            url: nil
        ))
    }

    /// Shows the lock screen; the session stays logged in. Called from the app
    /// itself because the login session agent isn't reachable from the XPC
    /// helper (it fails there with "Unable to get the SessionAgent endpoint").
    private func lockScreen() {
        typealias LockFunction = @convention(c) () -> Int32
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else {
            Log.app.error("lock: SACLockScreenImmediate unavailable")
            return
        }
        let result = unsafeBitCast(symbol, to: LockFunction.self)()
        Log.app.info("lock: SACLockScreenImmediate -> \(result, privacy: .public)")
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            // Not set up, switched off, or the token was rejected: idle until
            // that changes instead of hammering the server.
            guard client.canCallServer, Defaults[.demiffyReportMac] else {
                try? await Task.sleep(for: .seconds(30))
                continue
            }
            do {
                for command in try await client.pollCommands() {
                    run(command)
                }
            } catch {
                if client.noteRejection(error) { continue }
                // Offline, asleep, or the Pi restarting: try again shortly.
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func run(_ command: [String: Any]) {
        Log.app.info("demiffy command: \(command["type"] as? String ?? "?", privacy: .public)")
        switch command["type"] as? String {
        case "message":
            guard let text = command["text"] as? String else { return }
            SystemNotificationManager.shared.present(SystemNotification(
                id: command["id"] as? String ?? UUID().uuidString,
                appName: "Demiffy",
                bundleID: nil,
                title: "Message from demiffy.com",
                subtitle: nil,
                body: text,
                receivedAt: Date(),
                iconAsset: "DemiffyLogo",
                url: client.siteURL(path: "mac")
            ))
            NSSound(named: "Glass")?.play()
        case "playPause":
            MusicManager.shared.togglePlay()
        case "findSound":
            Task {
                for _ in 0..<6 {
                    NSSound(named: "Sosumi")?.play()
                    try? await Task.sleep(for: .milliseconds(900))
                }
            }
        case "lock":
            lockScreen()
        case "search":
            guard let searchId = command["searchId"] as? String, let query = command["query"] as? String else { return }
            Task { await self.answerSearch(searchId: searchId, query: query) }
        case "fetch":
            guard let fetchId = command["fetchId"] as? String, let path = command["path"] as? String else { return }
            Task { await self.answerFetch(fetchId: fetchId, path: path) }
        case "view":
            guard let viewID = command["viewId"] as? String, let bundleID = command["bundleId"] as? String else { return }
            startViewing(viewID: viewID, bundleID: bundleID)
            return
        case "viewInput":
            guard let viewID = command["viewId"] as? String, let events = command["events"] as? [[String: Any]] else { return }
            Task { await self.applyInput(viewID: viewID, events: events) }
            return
        case "getClipboard":
            guard let requestID = command["requestId"] as? String else { return }
            Task { await self.answerClipboard(requestID: requestID) }
            return
        case "setClipboard":
            guard let text = command["text"] as? String else { return }
            setClipboard(text)
        case "setVolume":
            guard let value = command["value"] as? Double else { return }
            VolumeManager.shared.setAbsolute(Float32(max(0, min(1, value))))
        case "setMute":
            guard let muted = command["muted"] as? Bool, muted != VolumeManager.shared.isMuted else { break }
            VolumeManager.shared.toggleMuteAction()
        case "setBrightness":
            guard let value = command["value"] as? Double else { return }
            BrightnessManager.shared.setAbsolute(value: Float(max(0, min(1, value))))
        default:
            break
        }
        reportSoon()
    }
}
