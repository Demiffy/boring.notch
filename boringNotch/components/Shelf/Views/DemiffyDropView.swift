//
//  DemiffyDropView.swift
//  boringNotch
//
//  The shelf tile next to AirDrop: drop files to upload them to Demiffy Cloud
//  and copy a share link; drop text and it becomes an inbox note.
//

import SwiftUI

struct DemiffyDropView: View {
    @ObservedObject private var client = DemiffyClient.shared
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: [Color.black.opacity(0.35), Color.black.opacity(0.20)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            isTargeted ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.1),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10])
                        )
                )
                .shadow(color: Color.black.opacity(0.6), radius: 6, x: 0, y: 2)

            VStack(spacing: 5) {
                badge
                    .frame(width: 55, height: 55)
                label
            }
            .padding(14)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText], isTargeted: $isTargeted) { providers in
            Task { await handleDrop(providers) }
            return true
        }
        .help(helpText)
        .animation(.spring(response: 0.36, dampingFraction: 0.75), value: client.uploadState)
        .animation(.spring(response: 0.36, dampingFraction: 0.7), value: isTargeted)
    }

    @ViewBuilder
    private var badge: some View {
        ZStack {
            Circle().fill(Color.white.opacity(isTargeted ? 0.11 : 0.09))

            switch client.uploadState {
            case .uploading(_, _, _, let progress):
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.15), value: progress)
                logo.opacity(0.85)
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            case .failed:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.red)
                    .transition(.scale.combined(with: .opacity))
            case .idle:
                logo
                    .scaleEffect(isTargeted ? 1.08 : 1)
            }
        }
    }

    private var logo: some View {
        Image("DemiffyLogo")
            .resizable()
            .scaledToFit()
            .frame(width: 32, height: 32)
    }

    @ViewBuilder
    private var label: some View {
        switch client.uploadState {
        case .uploading(_, let index, let count, let progress):
            VStack(spacing: 1) {
                Text("\(Int(progress * 100))%")
                    .font(.system(.headline, design: .rounded).monospacedDigit())
                    .foregroundColor(.white.opacity(0.85))
                if count > 1 {
                    Text("\(index) of \(count)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.gray)
                }
            }
        case .done(_, let count):
            Text(count > 1 ? "Links copied" : "Link copied")
                .font(.system(.headline, design: .rounded))
                .foregroundColor(.green.opacity(0.9))
        case .failed:
            Text("Failed")
                .font(.system(.headline, design: .rounded))
                .foregroundColor(.red.opacity(0.9))
        case .idle:
            Text(client.noteState == .saved ? "Noted" : "Demiffy")
                .font(.system(.headline, design: .rounded))
                .foregroundColor(.white.opacity(0.8))
        }
    }

    private var helpText: String {
        switch client.uploadState {
        case .uploading(let name, _, _, _): "Uploading \(name)…"
        case .done(let name, _): "\(name) is in Cloud/Notch — share link copied"
        case .failed(let message): message
        case .idle: "Drop files to upload them to Demiffy Cloud and copy a share link. Drop text to save it as a note."
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) async {
        var files: [URL] = []
        var texts: [String] = []
        for provider in providers {
            if let file = await provider.extractFileURL(), file.isFileURL {
                files.append(file)
            } else if let url = await provider.extractURL() {
                texts.append(url.absoluteString)
            } else if let text = await provider.extractText() {
                texts.append(text)
            }
        }
        if !files.isEmpty {
            await client.upload(files)
        } else if !texts.isEmpty {
            await client.saveDroppedText(texts.joined(separator: "\n"))
        }
    }
}
