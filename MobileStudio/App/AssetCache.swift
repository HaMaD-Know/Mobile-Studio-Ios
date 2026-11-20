import Foundation

/// Downloads and caches Roblox assets (port of net/AssetFetcher.kt + RobloxApi.download):
/// `rbxassetid://123`, `http(s)://www.roblox.com/asset/?id=123` and `rbxasset://` (bundled) URLs.
/// Order tried: Open Cloud API key, signed-in session, anonymous asset delivery.
final class AssetCache {
    static let shared = AssetCache()

    private let dir: URL
    private var pending: [Int64: [(URL?) -> Void]] = [:]
    private var failed: [Int64: Date] = [:]
    private(set) var lastError: [Int64: String] = [:]
    private let queue = DispatchQueue(label: "assets")

    /// Credentials set from Settings (stored in the Keychain by AccountStore).
    var apiKey: String { AccountStore.shared.apiKey ?? "" }
    var cookie: String { AccountStore.shared.cookie ?? "" }

    init() {
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Numeric asset id in a content string, if any (ImageLoader.assetId).
    static func assetId(_ content: String) -> Int64? {
        let s = content.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("rbxassetid://") { return Int64(s.dropFirst("rbxassetid://".count).prefix { $0.isNumber }) }
        if let r = s.range(of: "id=", options: .caseInsensitive) { return Int64(s[r.upperBound...].prefix { $0.isNumber }) }
        if !s.isEmpty, s.allSatisfy(\.isNumber) { return Int64(s) }
        return nil
    }

    func file(_ id: Int64) -> URL { dir.appendingPathComponent("\(id).bin") }

    func clear() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        failed.removeAll()
    }

    /// Local file for a content URL when already downloaded (or bundled).
    func localURL(for content: String) -> URL? {
        if content.hasPrefix("rbxasset://") {
            let path = String(content.dropFirst("rbxasset://".count))
            return Bundle.main.url(forResource: (path as NSString).deletingPathExtension, withExtension: (path as NSString).pathExtension, subdirectory: "rbxasset")
        }
        guard let id = AssetCache.assetId(content) else { return nil }
        let f = file(id)
        return FileManager.default.fileExists(atPath: f.path) ? f : nil
    }

    func data(for content: String) -> Data? { localURL(for: content).flatMap { try? Data(contentsOf: $0) } }

    /// Download in the background; `done` runs on the main queue with the cached file (or nil).
    func fetch(_ content: String, done: @escaping (URL?) -> Void = { _ in }) {
        if let u = localURL(for: content) { done(u); return }
        guard let id = AssetCache.assetId(content) else { done(nil); return }
        if let f = failed[id], Date().timeIntervalSince(f) < 90 { done(nil); return }
        if pending[id] != nil { pending[id]!.append(done); return }
        pending[id] = [done]
        Task.detached { [self] in
            var result: URL?
            var err: String?
            do {
                let bytes = try await self.download(id)
                try bytes.write(to: self.file(id), options: .atomic)
                result = self.file(id)
            } catch { err = error.localizedDescription }
            await MainActor.run {
                if result == nil { self.failed[id] = Date(); self.lastError[id] = err }
                let cbs = self.pending.removeValue(forKey: id) ?? []
                for cb in cbs { cb(result) }
            }
        }
    }

    enum AssetError: LocalizedError {
        case http(Int), noLocation, authRequired
        var errorDescription: String? {
            switch self {
            case .http(let c): "HTTP \(c)"
            case .noLocation: "No download location returned"
            case .authRequired: "Roblox requires sign-in (or an Open Cloud API key) to download this asset."
            }
        }
    }

    private func get(_ url: String, headers: [String: String] = [:]) async throws -> Data {
        var req = URLRequest(url: URL(string: url)!)
        req.setValue("MobileStudio/1.0", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw code == 401 || code == 403 ? AssetError.authRequired : AssetError.http(code) }
        return data
    }

    private func location(_ json: Data, key: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        if let l = obj[key] as? String { return l }
        if let arr = obj["locations"] as? [[String: Any]] { return arr.first?["location"] as? String }
        return nil
    }

    func download(_ id: Int64) async throws -> Data {
        var lastError: Error?
        if !apiKey.isEmpty {
            do {
                let j = try await get("https://apis.roblox.com/asset-delivery-api/v1/assetId/\(id)", headers: ["x-api-key": apiKey])
                if let loc = location(j, key: "location") { return try ungzip(try await get(loc)) }
                lastError = AssetError.noLocation
            } catch { lastError = error }
        }
        if !cookie.isEmpty {
            let h = ["Cookie": ".ROBLOSECURITY=" + cookie]
            do {
                let j = try await get("https://assetdelivery.roblox.com/v2/assetId/\(id)", headers: h)
                if let loc = location(j, key: "location") { return try ungzip(try await get(loc)) }
                return try ungzip(try await get("https://assetdelivery.roblox.com/v1/asset/?id=\(id)", headers: h))
            } catch { lastError = error }
        }
        do {
            return try ungzip(try await get("https://assetdelivery.roblox.com/v1/asset/?id=\(id)"))
        } catch {
            throw lastError ?? error
        }
    }

    private func ungzip(_ d: Data) throws -> Data {
        guard d.count > 2, d[d.startIndex] == 0x1F, d[d.startIndex + 1] == 0x8B else { return d }
        return try GzipData.unwrap(d)
    }
}

/// Gzip helper for the app target (same algorithm as StudioCore's reader).
enum GzipData {
    static func unwrap(_ b: Data) throws -> Data {
        let d = [UInt8](b)
        var p = 10
        let flags = d[3]
        if flags & 4 != 0 { p += 2 + (Int(d[p]) | (Int(d[p + 1]) << 8)) }
        if flags & 8 != 0 { while p < d.count && d[p] != 0 { p += 1 }; p += 1 }
        if flags & 16 != 0 { while p < d.count && d[p] != 0 { p += 1 }; p += 1 }
        if flags & 2 != 0 { p += 2 }
        guard p < d.count - 8 else { return b }
        return try (Data(d[p..<(d.count - 8)]) as NSData).decompressed(using: .zlib) as Data
    }
}
