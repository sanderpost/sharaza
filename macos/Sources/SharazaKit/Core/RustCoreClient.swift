import CSharazaFFI
import Foundation

public enum RustCoreError: LocalizedError, Sendable {
    case initializationFailed(String)
    case invocationFailed(String)
    case invalidPayload

    public var errorDescription: String? {
        switch self {
        case .initializationFailed(let msg): return "Rust Core initialization failed: \(msg)"
        case .invocationFailed(let msg): return msg
        case .invalidPayload: return "Invalid FFI response payload"
        }
    }
}

private struct FfiResponseEnvelope<T: Decodable>: Decodable {
    let ok: Bool
    let data: T?
    let error: String?
}

/// Thread-safe Swift wrapper around `SharazaCoreHandle` (`CSharazaFFI`), executing blocking/Tokio FFI work
/// off the `@MainActor` UI thread via structured concurrency.
public final class RustCoreClient: @unchecked Sendable {
    private let handle: OpaquePointer
    private let lock = NSLock()
    public let dataDirectory: URL

    public init(dataDirectory: URL? = nil) throws {
        let resolvedDir: URL
        if let dir = dataDirectory {
            resolvedDir = dir
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            resolvedDir = appSupport.appendingPathComponent("Sharaza", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: resolvedDir, withIntermediateDirectories: true)
        self.dataDirectory = resolvedDir

        var errPtr: UnsafeMutablePointer<CChar>? = nil
        let rawHandle = resolvedDir.path.withCString { cPath in
            sharaza_core_open(cPath, &errPtr)
        }

        if let rawHandle {
            self.handle = rawHandle
        } else {
            let message: String
            if let errPtr {
                message = String(cString: errPtr)
                sharaza_string_free(errPtr)
            } else {
                message = "Unknown error opening Rust core"
            }
            throw RustCoreError.initializationFailed(message)
        }
    }

    deinit {
        sharaza_core_close(handle)
    }

    // MARK: - Synchronous low-level FFI helpers

    public func callSync<Response: Decodable>(_ op: String, payloadJSON: String = "{}") throws -> Response {
        lock.lock()
        defer { lock.unlock() }

        let rawPtr: UnsafeMutablePointer<CChar>? = op.withCString { cOp in
            payloadJSON.withCString { cPayload in
                sharaza_core_request_json(handle, cOp, cPayload)
            }
        }
        guard let rawPtr else {
            throw RustCoreError.invalidPayload
        }
        defer { sharaza_string_free(rawPtr) }

        let jsonData = Data(String(cString: rawPtr).utf8)
        let env = try JSONDecoder().decode(FfiResponseEnvelope<Response>.self, from: jsonData)
        if env.ok, let data = env.data {
            return data
        }
        throw RustCoreError.invocationFailed(env.error ?? "Unknown FFI error")
    }

    public func callSyncEncodable<Req: Encodable, Resp: Decodable>(_ op: String, request: Req) throws -> Resp {
        let reqData = try JSONEncoder().encode(request)
        let reqStr = String(data: reqData, encoding: .utf8) ?? "{}"
        return try callSync(op, payloadJSON: reqStr)
    }

    // MARK: - Async APIs for SwiftUI

    public func loadConfig() throws -> AppConfig {
        try callSync("get_config")
    }

    public func saveConfig(_ config: AppConfig) throws {
        struct SavedAck: Decodable { let saved: Bool }
        let _: SavedAck = try callSyncEncodable("save_config", request: config)
    }

    public func previewPattern(
        _ pattern: String,
        windowTitle: String? = "Sharaza — Workspace",
        processName: String? = "Sharaza",
        width: UInt32 = 2560,
        height: UInt32 = 1440
    ) throws -> String {
        struct Req: Encodable {
            let pattern: String
            let window_title: String?
            let process_name: String?
            let width: UInt32
            let height: UInt32
            let preview: Bool
        }
        struct Resp: Decodable { let result: String }
        let resp: Resp = try callSyncEncodable(
            "parse_name",
            request: Req(
                pattern: pattern,
                window_title: windowTitle,
                process_name: processName,
                width: width,
                height: height,
                preview: true
            )
        )
        return resp.result
    }

    public func formatUploadLink(result: UploadResult, format: LinkFormat) throws -> String {
        struct Req: Encodable {
            let result: UploadResult
            let format: LinkFormat
        }
        struct Resp: Decodable { let formatted: String }
        let resp: Resp = try callSyncEncodable("format_upload_link", request: Req(result: result, format: format))
        return resp.formatted
    }

    public func queryHistory(_ filter: HistoryFilter = HistoryFilter()) async throws -> [HistoryItem] {
        try await Task.detached(priority: .userInitiated) {
            try self.callSyncEncodable("query_history", request: filter)
        }.value
    }

    public func deleteHistory(ids: [Int64]) async throws {
        struct Req: Encodable { let ids: [Int64] }
        struct Resp: Decodable { let deleted: Int }
        let _: Resp = try await Task.detached {
            try self.callSyncEncodable("delete_history", request: Req(ids: ids))
        }.value
    }

    public func clearHistory() async throws {
        struct Resp: Decodable { let cleared: Bool }
        let _: Resp = try await Task.detached {
            try self.callSync("clear_history")
        }.value
    }

    public func historyStats() async throws -> HistoryStats {
        try await Task.detached {
            try self.callSync("history_stats")
        }.value
    }

    public func importShareXHistory(jsonText: String) async throws -> Int {
        struct Req: Encodable { let json_text: String }
        struct Resp: Decodable { let imported: Int }
        let r: Resp = try await Task.detached {
            try self.callSyncEncodable("import_sharex_history", request: Req(json_text: jsonText))
        }.value
        return r.imported
    }

    public func listWorkflows() throws -> [WorkflowPreset] {
        try callSync("list_workflows")
    }

    public func saveWorkflow(_ preset: WorkflowPreset) throws {
        struct Resp: Decodable { let saved: Bool }
        let _: Resp = try callSyncEncodable("save_workflow", request: preset)
    }

    public func deleteWorkflow(id: String) throws {
        struct Req: Encodable { let id: String }
        struct Resp: Decodable { let deleted: Bool }
        let _: Resp = try callSyncEncodable("delete_workflow", request: Req(id: id))
    }

    public func listCustomUploaders() throws -> [CustomUploaderItem] {
        try callSync("list_custom_uploaders")
    }

    public func saveCustomUploader(sxcuJSON: String) throws -> CustomUploaderItem {
        try callSync("save_custom_uploader", payloadJSON: sxcuJSON)
    }

    public func deleteCustomUploader(name: String) throws {
        struct Req: Encodable { let name: String }
        struct Resp: Decodable { let deleted: Bool }
        let _: Resp = try callSyncEncodable("delete_custom_uploader", request: Req(name: name))
    }

    public func executeImageWorkflow(
        pngData: Data,
        metadata: CaptureMetadata,
        settings: TaskSettings,
        credentials: ResolvedCredentials
    ) async throws -> WorkflowExecutionReport {
        try await Task.detached(priority: .userInitiated) {
            try self.executeImageWorkflowSync(
                pngData: pngData,
                metadata: metadata,
                settings: settings,
                credentials: credentials
            )
        }.value
    }

    private func executeImageWorkflowSync(
        pngData: Data,
        metadata: CaptureMetadata,
        settings: TaskSettings,
        credentials: ResolvedCredentials
    ) throws -> WorkflowExecutionReport {
        let metaJSON = String(data: try JSONEncoder().encode(metadata), encoding: .utf8) ?? "{}"
        let settingsJSON = String(data: try JSONEncoder().encode(settings), encoding: .utf8) ?? "{}"
        let credsJSON = String(data: try JSONEncoder().encode(credentials), encoding: .utf8) ?? "{}"

        lock.lock()
        defer { lock.unlock() }

        let rawPtr: UnsafeMutablePointer<CChar>? = pngData.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return metaJSON.withCString { cMeta in
                settingsJSON.withCString { cSettings in
                    credsJSON.withCString { cCreds in
                        sharaza_execute_image_workflow_bytes(
                            self.handle,
                            base,
                            pngData.count,
                            cMeta,
                            cSettings,
                            cCreds
                        )
                    }
                }
            }
        }
        guard let rawPtr else { throw RustCoreError.invalidPayload }
        defer { sharaza_string_free(rawPtr) }

        let data = Data(String(cString: rawPtr).utf8)
        let env = try JSONDecoder().decode(FfiResponseEnvelope<WorkflowExecutionReport>.self, from: data)
        if env.ok, let report = env.data {
            return report
        }
        throw RustCoreError.invocationFailed(env.error ?? "Image workflow failed")
    }

    public func finalizeRecordingWorkflow(
        filePath: String,
        isGif: Bool,
        settings: TaskSettings,
        credentials: ResolvedCredentials
    ) async throws -> WorkflowExecutionReport {
        struct Req: Encodable {
            let recorded_file_path: String
            let is_gif: Bool
            let settings: TaskSettings
            let credentials: ResolvedCredentials
        }
        return try await Task.detached(priority: .userInitiated) {
            try self.callSyncEncodable(
                "finalize_recording_workflow",
                request: Req(
                    recorded_file_path: filePath,
                    is_gif: isGif,
                    settings: settings,
                    credentials: credentials
                )
            )
        }.value
    }

    public func uploadTextWorkflow(
        text: String,
        settings: TaskSettings,
        credentials: ResolvedCredentials
    ) async throws -> WorkflowExecutionReport {
        struct Req: Encodable {
            let text: String
            let settings: TaskSettings
            let credentials: ResolvedCredentials
        }
        return try await Task.detached(priority: .userInitiated) {
            try self.callSyncEncodable(
                "upload_text_workflow",
                request: Req(text: text, settings: settings, credentials: credentials)
            )
        }.value
    }

    public func uploadFileWorkflow(
        filePath: String,
        settings: TaskSettings,
        credentials: ResolvedCredentials
    ) async throws -> WorkflowExecutionReport {
        struct Req: Encodable {
            let file_path: String
            let settings: TaskSettings
            let credentials: ResolvedCredentials
        }
        return try await Task.detached(priority: .userInitiated) {
            try self.callSyncEncodable(
                "upload_file_workflow",
                request: Req(file_path: filePath, settings: settings, credentials: credentials)
            )
        }.value
    }

    public func shortenURL(
        shortener: BuiltinUrlShortener,
        url: String,
        credentials: ResolvedCredentials,
        customUploaderName: String? = nil
    ) async throws -> String {
        struct Req: Encodable {
            let shortener: BuiltinUrlShortener
            let url: String
            let credentials: ResolvedCredentials
            let custom_uploader_name: String?
        }
        struct Resp: Decodable { let shortened_url: String }
        let r: Resp = try await Task.detached {
            try self.callSyncEncodable(
                "shorten_url",
                request: Req(
                    shortener: shortener,
                    url: url,
                    credentials: credentials,
                    custom_uploader_name: customUploaderName
                )
            )
        }.value
        return r.shortened_url
    }

    // MARK: - Binary Buffer Operations (Beautifier, QR, Scrolling Stitcher)

    public static func beautifyPNG(_ pngData: Data, effects: ImageEffectsConfig = ImageEffectsConfig()) throws -> Data {
        let cfgJSON = String(data: try JSONEncoder().encode(effects), encoding: .utf8) ?? "{}"
        let buf: SharazaByteBuffer = pngData.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                return SharazaByteBuffer(ptr: nil, len: 0, width: 0, height: 0, status_code: -1, error: nil)
            }
            return cfgJSON.withCString { cJson in
                sharaza_beautify_image_png(base, pngData.count, cJson)
            }
        }
        defer { sharaza_buffer_free(buf) }
        if let err = buf.error {
            throw RustCoreError.invocationFailed(String(cString: err))
        }
        guard let ptr = buf.ptr, buf.len > 0 else {
            throw RustCoreError.invalidPayload
        }
        return Data(bytes: ptr, count: buf.len)
    }

    public static func generateQRCodePNG(text: String, moduleSize: UInt32 = 8) throws -> Data {
        let buf = text.withCString { cStr in
            sharaza_generate_qr_png(cStr, moduleSize)
        }
        defer { sharaza_buffer_free(buf) }
        if let err = buf.error {
            throw RustCoreError.invocationFailed(String(cString: err))
        }
        guard let ptr = buf.ptr, buf.len > 0 else {
            throw RustCoreError.invalidPayload
        }
        return Data(bytes: ptr, count: buf.len)
    }

    public static func stitchScrollingPNGFrames(_ frames: [Data], autoIgnoreBottom: Bool = true) throws -> Data {
        guard !frames.isEmpty else {
            throw RustCoreError.invocationFailed("No scrolling frames captured")
        }
        let lengths = frames.map { $0.count }
        let nsDatas = frames.map { $0 as NSData }
        let ptrs: [UnsafePointer<UInt8>?] = nsDatas.indices.map { idx in
            nsDatas[idx].bytes.assumingMemoryBound(to: UInt8.self)
        }

        let buf = ptrs.withUnsafeBufferPointer { ptrBuf in
            lengths.withUnsafeBufferPointer { lenBuf in
                sharaza_stitch_scrolling_pngs(ptrBuf.baseAddress, lenBuf.baseAddress, frames.count, autoIgnoreBottom)
            }
        }
        defer { sharaza_buffer_free(buf) }
        if let err = buf.error {
            throw RustCoreError.invocationFailed(String(cString: err))
        }
        guard let ptr = buf.ptr, buf.len > 0 else {
            throw RustCoreError.invalidPayload
        }
        return Data(bytes: ptr, count: buf.len)
    }

    public func computeFileHashes(path: String) async throws -> FileHashes {
        struct Req: Encodable { let file_path: String }
        return try await Task.detached {
            try self.callSyncEncodable("compute_hashes_file", request: Req(file_path: path))
        }.value
    }

    public func computeTextHashes(text: String) throws -> FileHashes {
        struct Req: Encodable { let text: String }
        return try callSyncEncodable("compute_hashes_text", request: Req(text: text))
    }

    public func convertColor(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) throws -> ColorFormats {
        struct Req: Encodable { let r: UInt8; let g: UInt8; let b: UInt8; let a: UInt8 }
        return try callSyncEncodable("convert_color", request: Req(r: r, g: g, b: b, a: a))
    }
}
