//
//  BackgroundAppsView.swift
//  boringNotch
//
//  The Apps tab of the open notch: apps running without a Dock icon (menu
//  bar apps like Stats or Raycast), so you can still see and open them when
//  their menu bar icon is turned off in System Settings > Menu Bar.
//

import AppKit
import SwiftUI

@MainActor
final class BackgroundApps: ObservableObject {
    static let shared = BackgroundApps()

    @Published private(set) var apps: [NSRunningApplication] = []
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in BackgroundApps.shared.refresh() }
            })
        }
        refresh()
    }

    func refresh() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        apps = NSWorkspace.shared.runningApplications
            .filter { app in
                guard app.activationPolicy == .accessory, !app.isTerminated,
                      app.processIdentifier != ownPID,
                      let path = app.bundleURL?.path else { return false }
                // Not macOS's own agents, and not helper processes nested inside another app.
                return !path.hasPrefix("/System/")
                    && !(app.bundleIdentifier ?? "").hasPrefix("com.apple.")
                    && !path.dropLast(4).contains(".app/")
            }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
    }

    /// Launching a running menu bar app usually brings up its settings window.
    func open(_ app: NSRunningApplication) {
        guard let url = app.bundleURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    func quit(_ app: NSRunningApplication) {
        XPCHelperClient.shared.quitApplication(pid: app.processIdentifier)
    }
}

struct BackgroundAppsView: View {
    @ObservedObject private var model = BackgroundApps.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Background apps")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Text(model.apps.isEmpty ? "" : "\(model.apps.count) running · click to open")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.gray)
            }

            if model.apps.isEmpty {
                Text("No menu bar apps are running.")
                    .font(.system(size: 12))
                    .foregroundStyle(.gray)
                    .padding(.top, 6)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(model.apps, id: \.processIdentifier) { app in
                            BackgroundAppTile(app: app, open: { model.open(app) }, quit: { model.quit(app) })
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.never)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .onAppear { model.refresh() }
        .animation(.smooth(duration: 0.25), value: model.apps.map(\.processIdentifier))
    }
}

private struct BackgroundAppTile: View {
    let app: NSRunningApplication
    let open: () -> Void
    let quit: () -> Void
    @State private var hovering = false

    private var name: String { app.localizedName ?? "App" }

    var body: some View {
        Button(action: open) {
            VStack(spacing: 5) {
                Group {
                    if let icon = app.icon {
                        Image(nsImage: icon).resizable().scaledToFit()
                    } else {
                        Image(systemName: "app.dashed").foregroundStyle(.gray)
                    }
                }
                .frame(width: 34, height: 34)
                .frame(width: 52, height: 46)
                .background(RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(hovering ? 0.14 : 0.07)))
                .overlay(alignment: .topTrailing) {
                    if hovering {
                        Button(action: quit) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 16, height: 16)
                                .background(Circle().fill(Color.black.opacity(0.85)))
                                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                        .help("Quit \(name)")
                        .accessibilityLabel("Quit \(name)")
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                Text(name)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.gray)
                    .lineLimit(1)
                    .frame(width: 60)
            }
        }
        .buttonStyle(.plain)
        .onHover { hover in withAnimation(.easeOut(duration: 0.15)) { hovering = hover } }
        .contextMenu {
            Button("Open \(name)", action: open)
            Button("Quit \(name)", action: quit)
        }
        .help("Open \(name)")
        .accessibilityLabel("Open \(name)")
    }
}
