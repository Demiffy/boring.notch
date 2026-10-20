//
//  DemiffyClient.swift
//  boringNotch
//
//  Talks to demiffy.com's API with a notch-scoped device token: drop a file to
//  upload it into Cloud/Notch and copy a share link, or save a quick note to
//  the inbox. The token lives in the Keychain; everything else in Defaults.
//

import AppKit
import Defaults
import Security

@MainActor
final class DemiffyClient: ObservableObject {
    static let shared = DemiffyClient()

    enum UploadState: Equatable {
        case idle
        /// `index` is 1-based; `progress` covers the current file only.
        case uploading(name: String, index: Int, count: Int, progress: Double)
        case done(name: String, count: Int)
        case failed(String)
    }

    enum NoteState: Equatable {
        case idle, saving, saved, failed(String)
    }

    @Published private(set) var uploadState: UploadState = .idle
    @Published private(set) var noteState: NoteState = .idle
    @Published private(set) var hasToken: Bool
    /// The draft survives the notch closing; cleared once it's saved.
    @Published var noteDraft = ""

    /// Cloudflare caps one request at 100 MB; the API's own single-request limit is 95 MB.
    static let maxUploadBytes = 95 * 1024 * 1024
    private static let keychainService = "com.demiffy.notch"
    private static let keychainAccount = "device-token"

    private var uploadReset: Task<Void, Never>?
    private var noteReset: Task<Void, Never>?

    private init() {
        hasToken = Self.readToken() != nil
    }

    var isConfigured: Bool { hasToken && serverURL != nil }

    private var serverURL: URL? {
        let raw = Defaults[.demiffyServer].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), url.scheme == "https" || url.host == "localhost" || url.host == "127.0.0.1" else { return nil }
        return url
    }

    // MARK: - Token

    func setToken(_ token: String) {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.deleteToken()
        if !token.isEmpty {
            let item: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.keychainService,
                kSecAttrAccount as String: Self.keychainAccount,
                kSecValueData as String: Data(token.utf8),
            ]
            SecItemAdd(item as CFDictionary, nil)
        }
        hasToken = Self.readToken() != nil
    }

    private static func readToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Requests

    private func request(_ path: String, method: String = "GET") throws -> URLRequest {
        guard let base = serverURL, let token = Self.readToken() else { throw DemiffyError("Connect Demiffy in Settings first") }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        return request
    }

    /// Returns the display name the token belongs to.
    func testConnection() async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: request("notch/me"))
        try Self.check(data, response)
        struct Me: Decodable { let displayName: String }
        return try JSONDecoder().decode(Me.self, from: data).displayName
    }

    // MARK: - Notes

    func saveNote() async {
        let text = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, noteState != .saving else { return }
        noteState = .saving
        do {
            var request = try request("notch/notes", method: "POST")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.check(data, response)
            noteDraft = ""
            noteState = .saved
            NSSound(named: "Pop")?.play()
        } catch {
            noteState = .failed(Self.message(for: error))
        }
        noteReset?.cancel()
        noteReset = after(noteState == .saved ? 2 : 4) { $0.noteState = .idle }
    }

    // MARK: - Upload

    /// Uploads each file in turn and copies the share links (one per line).
    func upload(_ fileURLs: [URL]) async {
        if case .uploading = uploadState { return }
        let files = fileURLs.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        guard !files.isEmpty else {
            fail("Only files can go to the Cloud — not folders")
            return
        }
        uploadReset?.cancel()

        var links: [String] = []
        for (offset, file) in files.enumerated() {
            let name = file.lastPathComponent
            uploadState = .uploading(name: name, index: offset + 1, count: files.count, progress: 0)
            do {
                links.append(try await upload(file) { [weak self] progress in
                    self?.uploadState = .uploading(name: name, index: offset + 1, count: files.count, progress: progress)
                })
            } catch {
                fail("\(name): \(Self.message(for: error))")
                copyLinks(links)
                return
            }
        }
        copyLinks(links)
        uploadState = .done(name: files.count == 1 ? files[0].lastPathComponent : "\(files.count) files", count: files.count)
        NSSound(named: "Glass")?.play()
        uploadReset = after(4) { $0.uploadState = .idle }
    }

    /// Text dropped on the Cloud tile becomes a note instead.
    func saveDroppedText(_ text: String) async {
        noteDraft = text
        await saveNote()
    }

    private func upload(_ file: URL, progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> String {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maxUploadBytes else {
            throw DemiffyError("Over 95 MB — upload it from the Cloud page")
        }

        // Files dragged out of the shelf are security-scoped bookmarks.
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }

        let boundary = "notch-\(UUID().uuidString)"
        var request = try request("notch/upload", method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600

        let body = try Self.multipartFile(for: file, boundary: boundary, expiryHours: Defaults[.demiffyLinkExpiryHours])
        defer { try? FileManager.default.removeItem(at: body) }

        let delegate = UploadProgressDelegate { fraction in
            Task { @MainActor in progress(fraction) }
        }
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: body, delegate: delegate)
        try Self.check(data, response)
        struct Uploaded: Decodable { let url: String }
        return try JSONDecoder().decode(Uploaded.self, from: data).url
    }

    /// Streams the form to a temp file so a 90 MB video never sits in memory.
    private static func multipartFile(for file: URL, boundary: String, expiryHours: Int) throws -> URL {
        let body = FileManager.default.temporaryDirectory.appendingPathComponent("notch-upload-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: body.path, contents: nil)
        let out = try FileHandle(forWritingTo: body)
        defer { try? out.close() }

        let filename = file.lastPathComponent.replacingOccurrences(of: "\"", with: "'")
        var head = "--\(boundary)\r\nContent-Disposition: form-data; name=\"expiresInHours\"\r\n\r\n\(expiryHours)\r\n"
        head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
        head += "Content-Type: application/octet-stream\r\n\r\n"
        try out.write(contentsOf: Data(head.utf8))

        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
        try out.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    // MARK: - Helpers

    private func copyLinks(_ links: [String]) {
        guard !links.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
    }

    private func fail(_ message: String) {
        uploadState = .failed(message)
        NSSound(named: "Basso")?.play()
        uploadReset?.cancel()
        uploadReset = after(5) { $0.uploadState = .idle }
    }

    private func after(_ seconds: Double, _ reset: @escaping @MainActor (DemiffyClient) -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            reset(self)
        }
    }

    private static func check(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw DemiffyError("No response from the server") }
        guard !(200..<300).contains(http.statusCode) else { return }
        if http.statusCode == 401 { throw DemiffyError("Token not accepted — make a new one in Settings") }
        struct Body: Decodable { struct Err: Decodable { let message: String }; let error: Err }
        let message = (try? JSONDecoder().decode(Body.self, from: data))?.error.message
        throw DemiffyError(message ?? "Server answered \(http.statusCode)")
    }

    private static func message(for error: Error) -> String {
        if let error = error as? DemiffyError { return error.message }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost: return "You're offline"
            case .timedOut: return "The server took too long"
            case .cannotFindHost, .cannotConnectToHost: return "Can't reach the server"
            default: break
            }
        }
        return error.localizedDescription
    }
}

struct DemiffyError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    let onProgress: @Sendable (Double) -> Void
    init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
