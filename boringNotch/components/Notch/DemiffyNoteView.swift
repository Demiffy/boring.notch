//
//  DemiffyNoteView.swift
//  boringNotch
//
//  The Note tab: type a thought, ⌘↩, and it lands in the Demiffy notes inbox.
//  The first line becomes the note's title.
//

import SwiftUI

struct DemiffyNoteView: View {
    @ObservedObject private var client = DemiffyClient.shared
    @FocusState private var focused: Bool
    /// True while we hold the notch open, so moving the pointer away mid-sentence doesn't close it.
    @State private var holdingOpen = false

    private var trimmedDraft: String { client.noteDraft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Image("DemiffyLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                Text("Quick note")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.white)
                Text("Goes to your Demiffy inbox. First line is the title.")
                    .font(.system(size: 11))
                    .foregroundStyle(.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 120, alignment: .leading)

            VStack(alignment: .trailing, spacing: 8) {
                editor
                footer
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .background(KeyWindowEnabler())
        .onAppear { focused = true }
        .onChange(of: focused) { _, _ in updateHold() }
        .onChange(of: client.noteDraft) { _, _ in updateHold() }
        .onDisappear { releaseHold() }
        // The panel only takes the keyboard once KeyWindowEnabler made it key,
        // which lands after onAppear; focus the editor then so typing just works.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if note.object is BoringNotchSkyLightWindow { focused = true }
        }
        // Clicking into another app takes the keyboard away; stop holding the notch open then.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            if note.object is BoringNotchSkyLightWindow { focused = false }
        }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(focused ? Color.accentColor.opacity(0.7) : Color.white.opacity(0.1), lineWidth: 1)
                )

            if client.noteDraft.isEmpty {
                Text("What's on your mind?")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $client.noteDraft)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .focused($focused)
                .padding(.horizontal, 7)
                .padding(.vertical, 8)
                .disabled(client.noteState == .saving)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: focused)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            status
            Spacer(minLength: 0)
            Button {
                Task { await client.saveNote() }
            } label: {
                HStack(spacing: 5) {
                    if client.noteState == .saving {
                        ProgressView().controlSize(.mini).tint(.white)
                    }
                    Text("Save")
                    Text("⌘↩").foregroundStyle(.white.opacity(0.55))
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(trimmedDraft.isEmpty ? Color.white.opacity(0.08) : Color.accentColor))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(trimmedDraft.isEmpty || client.noteState == .saving)
            .accessibilityLabel("Save note to Demiffy")
        }
        .animation(.easeOut(duration: 0.2), value: client.noteState)
    }

    @ViewBuilder
    private var status: some View {
        switch client.noteState {
        case .saved:
            Label("Saved to inbox", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(1)
                .help(message)
        case .idle, .saving:
            if !client.noteDraft.isEmpty {
                Text(client.noteDraft.count == 1 ? "1 character" : "\(client.noteDraft.count) characters")
                    .foregroundStyle(.gray)
            }
        }
    }

    private func updateHold() {
        let shouldHold = focused && !trimmedDraft.isEmpty
        if shouldHold && !holdingOpen {
            SharingStateManager.shared.beginInteraction()
            holdingOpen = true
        } else if !shouldHold {
            releaseHold()
        }
    }

    private func releaseHold() {
        guard holdingOpen else { return }
        holdingOpen = false
        SharingStateManager.shared.endInteraction()
    }
}

/// The notch panel refuses keyboard focus by default so it never steals it from
/// the frontmost app. This lets it take focus only while the note editor is on screen.
private struct KeyWindowEnabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        private weak var notchWindow: BoringNotchSkyLightWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window = window as? BoringNotchSkyLightWindow {
                notchWindow = window
                window.wantsKeyForTextInput = true
            } else {
                notchWindow?.wantsKeyForTextInput = false
                notchWindow = nil
            }
        }
    }
}
