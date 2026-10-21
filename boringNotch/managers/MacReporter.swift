//
//  MacReporter.swift
//  boringNotch
//
//  Reports this Mac to demiffy.com (/mac) and runs the safe commands the site
//  sends back: a message in the notch, play/pause, a find-my-Mac sound, lock.
//  Reports go out every minute and shortly after anything worth showing
//  changes; commands arrive over one long-poll, so they land in about a second.
//

import AppKit
import Combine
import Defaults

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

    private init() {}

    func start() {
        guard reportTask == nil else { return }
        reportTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.report()
                try? await Task.sleep(for: .seconds(60))
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
            try await client.postJSON("notch/report", body: snapshot(sleeping: sleeping))
        } catch {
            client.noteRejection(error)
        }
    }

    private func snapshot(sleeping: Bool) -> [String: Any] {
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

        var body: [String: Any] = ["state": sleeping ? "sleeping" : "awake", "vitals": vitals]

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
        default:
            break
        }
        reportSoon()
    }
}
