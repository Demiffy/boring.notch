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
