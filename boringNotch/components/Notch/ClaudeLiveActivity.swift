//
//  ClaudeLiveActivity.swift
//  boringNotch
//

import SwiftUI

struct ClaudeLiveActivity: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var manager = ClaudeCodeStatusManager.shared

    @State private var spin = false
    @State private var ringScale: CGFloat = 1
    @State private var ringOpacity = 0.0

    static let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)

    private var itemSize: CGFloat {
        max(0, vm.effectiveClosedNotchHeight - 12)
    }

    var body: some View {
        HStack {
            Image(systemName: "sparkle")
                .font(.system(size: itemSize * 0.7, weight: .semibold))
                .foregroundStyle(Self.claudeOrange)
                .frame(width: itemSize, height: itemSize)

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width - cornerRadiusInsets.closed.top)

            indicator
                .frame(width: itemSize, height: itemSize)
        }
        .frame(height: vm.effectiveClosedNotchHeight)
        .onChange(of: manager.overallState) { _, state in
            if state == .done || state == .waiting || state == .failed { pulse() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var indicator: some View {
        switch manager.overallState {
        case .working:
            ZStack {
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(Self.claudeOrange, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
                    .onDisappear { spin = false }
                if manager.workingCount > 1 {
                    Text("\(manager.workingCount)")
                        .font(.system(size: itemSize * 0.45, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            .padding(2)
        case .waiting:
            statusIcon("exclamationmark", color: Self.claudeOrange)
        case .done:
            statusIcon("checkmark", color: .green)
        case .failed:
            statusIcon("xmark", color: .red)
        case nil:
            EmptyView()
        }
    }

    private func statusIcon(_ name: String, color: Color) -> some View {
        ZStack {
            Circle()
                .stroke(color, lineWidth: 1.5)
                .scaleEffect(ringScale)
                .opacity(ringOpacity)
            Image(systemName: name)
                .font(.system(size: itemSize * 0.55, weight: .bold))
                .foregroundStyle(color)
        }
    }

    private func pulse() {
        ringScale = 1
        ringOpacity = 0.8
        withAnimation(.easeOut(duration: 0.6)) {
            ringScale = 1.8
            ringOpacity = 0
        }
    }

    private var accessibilityText: String {
        switch manager.overallState {
        case .working: "Claude is working"
        case .waiting: "Claude needs your input"
        case .done: "Claude is done"
        case .failed: "Claude stopped with an error"
        case nil: "Claude"
        }
    }
}

/// The Claude tab of the open notch: every session Claude Code reported,
/// most urgent first, with how long the current turn has been running.
struct ClaudeSessionsView: View {
    @ObservedObject private var manager = ClaudeCodeStatusManager.shared

    private static let order: [ClaudeSessionState] = [.waiting, .failed, .working, .done]

    private var sessions: [ClaudeSession] {
        manager.sessions.values.sorted {
            let a = Self.order.firstIndex(of: $0.state) ?? 0
            let b = Self.order.firstIndex(of: $1.state) ?? 0
            return a != b ? a < b : $0.startedAt < $1.startedAt
        }
    }

    private var summary: String {
        let counts = Dictionary(grouping: manager.sessions.values, by: \.state).mapValues(\.count)
        let parts: [(ClaudeSessionState, String)] = [(.working, "working"), (.waiting, "needs you"), (.failed, "stopped"), (.done, "done")]
        return parts.compactMap { state, label in counts[state].map { "\($0) \(label)" } }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ClaudeLiveActivity.claudeOrange)
                Text("Claude Code")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Text(summary)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.gray)
            }

            ScrollView(.vertical) {
                VStack(spacing: 4) {
                    ForEach(sessions) { session in
                        ClaudeSessionRow(session: session)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .animation(.smooth(duration: 0.25), value: sessions.map(\.id))
    }
}

private struct ClaudeSessionRow: View {
    let session: ClaudeSession
    @State private var spin = false

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 0) {
                Text(session.project)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(stateText)
                    .font(.system(size: 11))
                    .foregroundStyle(stateColor.opacity(0.9))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.elapsed(from: session.startedAt, to: session.state == .working || session.state == .waiting ? context.date : session.updatedAt))
                    .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.gray)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(session.state == .waiting ? 0.09 : 0.05)))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        switch session.state {
        case .working:
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(ClaudeLiveActivity.claudeOrange, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
                .onAppear { spin = true }
                .padding(2)
        case .waiting:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(ClaudeLiveActivity.claudeOrange)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private var stateText: String {
        switch session.state {
        case .working: "Working"
        case .waiting: "Needs your input"
        case .done: "Done"
        case .failed: "Stopped — usage limit or API error"
        }
    }

    private var stateColor: Color {
        switch session.state {
        case .working: .gray
        case .waiting: ClaudeLiveActivity.claudeOrange
        case .done: .green
        case .failed: .red
        }
    }

    static func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(String(format: "%02d", seconds % 60))s" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }
}
