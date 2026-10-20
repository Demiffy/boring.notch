//
//  DemiffySettingsView.swift
//  boringNotch
//

import Defaults
import SwiftUI

struct DemiffySettingsView: View {
    @ObservedObject private var client = DemiffyClient.shared
    @Default(.demiffyServer) private var server
    @Default(.demiffyLinkExpiryHours) private var expiryHours
    @Default(.demiffyReportMac) private var reportMac

    @State private var tokenInput = ""
    @State private var connection: Connection = .unknown

    private enum Connection: Equatable {
        case unknown, checking, connected(String), failed(String)
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image("DemiffyLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 34, height: 34)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 9).fill(.black))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Demiffy").font(.headline)
                        Text("Drop files on the notch to share them from your Cloud, and jot quick notes into your inbox.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }

            Section {
                TextField("Server", text: $server, prompt: Text("https://api.demiffy.com"))
                if client.hasToken {
                    LabeledContent("Device token") {
                        HStack {
                            Text("Saved in Keychain").foregroundStyle(.secondary)
                            Button("Remove", role: .destructive) {
                                client.setToken("")
                                connection = .unknown
                            }
                        }
                    }
                } else {
                    HStack {
                        SecureField("Device token", text: $tokenInput, prompt: Text("dvt_…"))
                        Button("Save") {
                            client.setToken(tokenInput)
                            tokenInput = ""
                            Task { await test() }
                        }
                        .disabled(!tokenInput.trimmingCharacters(in: .whitespaces).hasPrefix("dvt_"))
                    }
                }
                HStack {
                    connectionStatus
                    Spacer()
                    Button("Test connection") { Task { await test() } }
                        .disabled(!client.hasToken || connection == .checking)
                }
            } header: {
                Text("Account")
            } footer: {
                HStack(spacing: 4) {
                    Text("Create a token on")
                    Link("demiffy.com → Settings → Boring Notch", destination: URL(string: "https://demiffy.com/settings#notch")!)
                }
                .font(.caption)
            }

            Section {
                Defaults.Toggle(key: .demiffyReportMac) {
                    Text("Report this Mac to demiffy.com")
                }
                Defaults.Toggle(key: .demiffyShareNowPlaying) {
                    Text("Include what's playing")
                }
                .disabled(!reportMac)
                Defaults.Toggle(key: .demiffyShareActivity) {
                    Text("Include the app in front and lock state")
                }
                .disabled(!reportMac)
            } header: {
                Text("This Mac")
            } footer: {
                HStack(spacing: 4) {
                    Text("Battery, CPU, memory and disk every minute, and remote actions (message, play/pause, sound, lock) from")
                    Link("demiffy.com/mac", destination: URL(string: "https://demiffy.com/mac")!)
                }
                .font(.caption)
            }

            Section {
                Picker("Share links expire after", selection: $expiryHours) {
                    Text("1 day").tag(24)
                    Text("7 days").tag(24 * 7)
                    Text("30 days").tag(24 * 30)
                    Text("Never").tag(0)
                }
            } header: {
                Text("Cloud drop")
            } footer: {
                Text("Files land in Cloud/Notch and the share link is copied as soon as the upload finishes. Up to 95 MB per file; dropping text saves it as a note instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Demiffy")
        .task { if client.hasToken { await test() } }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch connection {
        case .unknown:
            Label(client.hasToken ? "Not checked yet" : "Not connected", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        case .connected(let name):
            Label("Connected as \(name)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private func test() async {
        connection = .checking
        do {
            connection = .connected(try await client.testConnection())
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }
}
