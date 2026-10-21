//
//  ClaudeLiveActivity.swift
//  boringNotch
//

import SwiftUI

struct ClaudeLiveActivity: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var manager = ClaudeCodeStatusManager.shared

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
                ArcSpinner(color: NSColor(Self.claudeOrange))
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


/// A spinning arc rotated by Core Animation in the window server. A SwiftUI
/// `repeatForever` rotation re-renders the view every display frame on the
/// main thread (~8% CPU for as long as Claude works); this costs the app
/// nothing per frame.
struct ArcSpinner: NSViewRepresentable {
    let color: NSColor
    var lineWidth: CGFloat = 2

    func makeNSView(context: Context) -> SpinnerView {
        SpinnerView(color: color, lineWidth: lineWidth)
    }

    func updateNSView(_ view: SpinnerView, context: Context) {}

    final class SpinnerView: NSView {
        private let arc = CAShapeLayer()

        init(color: NSColor, lineWidth: CGFloat) {
            super.init(frame: .zero)
            wantsLayer = true
            arc.fillColor = nil
            arc.strokeColor = color.cgColor
            arc.lineWidth = lineWidth
            arc.lineCap = .round
            arc.strokeEnd = 0.7
            layer?.addSublayer(arc)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            arc.frame = bounds
            let inset = arc.lineWidth / 2
            arc.path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
            restartRotation()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            restartRotation()
        }

        private func restartRotation() {
            arc.removeAnimation(forKey: "spin")
            guard window != nil, bounds.width > 0 else { return }
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 0.9
            spin.repeatCount = .infinity
            arc.add(spin, forKey: "spin")
        }
    }
}
