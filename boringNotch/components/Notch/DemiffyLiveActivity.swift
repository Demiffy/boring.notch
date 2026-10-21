//
//  DemiffyLiveActivity.swift
//  boringNotch
//
//  Closed-notch view of a Demiffy Cloud upload: the logo on the left, a
//  progress ring on the right that turns into a check once the link is copied.
//

import SwiftUI

struct DemiffyLiveActivity: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var client = DemiffyClient.shared

    private var itemSize: CGFloat { max(0, vm.effectiveClosedNotchHeight - 12) }

    var body: some View {
        HStack {
            Image("DemiffyLogo")
                .resizable()
                .scaledToFit()
                .frame(width: itemSize, height: itemSize)

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width - cornerRadiusInsets.closed.top)

            indicator
                .frame(width: itemSize, height: itemSize)
        }
        .frame(height: vm.effectiveClosedNotchHeight)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: client.uploadState)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var indicator: some View {
        switch client.uploadState {
        case .uploading(_, _, _, let progress):
            ZStack {
                Circle().stroke(Color.white.opacity(0.15), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.03, progress))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.15), value: progress)
            }
            .padding(2)
        case .done:
            Image(systemName: "link")
                .font(.system(size: itemSize * 0.5, weight: .bold))
                .foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))
        case .failed:
            Image(systemName: "exclamationmark")
                .font(.system(size: itemSize * 0.55, weight: .bold))
                .foregroundStyle(.red)
                .transition(.scale.combined(with: .opacity))
        case .idle:
            EmptyView()
        }
    }

    private var accessibilityText: String {
        switch client.uploadState {
        case .uploading(let name, _, _, let progress): "Uploading \(name) to Demiffy, \(Int(progress * 100)) percent"
        case .done: "Uploaded to Demiffy, link copied"
        case .failed(let message): "Demiffy upload failed: \(message)"
        case .idle: "Demiffy"
        }
    }
}
