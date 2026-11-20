import Foundation

/// Roblox web APIs the app uses (port of net/RobloxApi.kt + net/RobloxCloud.kt): Toolbox search,
/// the signed-in user's experiences and places, place download and Open Cloud publishing.
enum RobloxWeb {
    struct WebError: LocalizedError { let message: String; var errorDescription: String? { message } }

    private static var csrf: String?

    static func request(_ url: String, method: String = "GET", body: Data? = nil, contentType: String? = nil,
                        headers: [String: String] = [:], authed: Bool = false) async throws -> (Data, HTTPURLResponse) {
        guard let u = URL(string: url) else { throw WebError(message: "Bad URL") }
        func make(_ token: String?) -> URLRequest {
            var r = URLRequest(url: u)
            r.httpMethod = method
            r.httpBody = body
            r.setValue("MobileStudio/1.0", forHTTPHeaderField: "User-Agent")
            if let contentType { r.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
            if authed, let c = AccountStore.shared.cookie { r.setValue(".ROBLOSECURITY=" + c, forHTTPHeaderField: "Cookie") }
            if let token { r.setValue(token, forHTTPHeaderField: "X-CSRF-TOKEN") }
            return r
        }
        if authed && AccountStore.shared.cookie == nil {
            throw WebError(message: "Sign in to your Roblox account first (Settings → Account).")
        }
        var (data, resp) = try await URLSession.shared.data(for: make(csrf))
        var http = resp as! HTTPURLResponse
        // Roblox asks for a CSRF token on the first state-changing request.
        if http.statusCode == 403, let tok = http.value(forHTTPHeaderField: "x-csrf-token"), tok != csrf {
            csrf = tok
            (data, resp) = try await URLSession.shared.data(for: make(tok))
            http = resp as! HTTPURLResponse
        }
        if authed && http.statusCode == 401 { throw WebError(message: "Your Roblox sign-in has expired. Sign in again.") }
        return (data, http)
    }

    static func json(_ url: String, authed: Bool = false) async throws -> [String: Any] {
        let (d, r) = try await request(url, authed: authed)
        guard (200..<300).contains(r.statusCode) else { throw WebError(message: "HTTP \(r.statusCode)") }
        return (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }

    // MARK: account

    struct User { let id: Int64; let name: String; let displayName: String }

    static func currentUser() async throws -> User {
        let j = try await json("https://users.roblox.com/v1/users/authenticated", authed: true)
        return User(id: (j["id"] as? NSNumber)?.int64Value ?? 0, name: j["name"] as? String ?? "", displayName: j["displayName"] as? String ?? "")
    }

    static func logout() async {
        _ = try? await request("https://auth.roblox.com/v2/logout", method: "POST", authed: true)
    }

    // MARK: Toolbox

    enum Category: Int, CaseIterable, Identifiable {
        case models = 10, decals = 13, audio = 3, meshes = 40
        var id: Int { rawValue }
        var label: String {
            switch self { case .models: "Models"; case .decals: "Decals"; case .audio: "Audio"; case .meshes: "Meshes" }
        }
    }

    struct Item: Identifiable { let id: Int64; let name: String; let creator: String; var thumbnail: URL? }

    static func search(_ keyword: String, _ cat: Category, cursor: String? = nil) async throws -> ([Item], String?) {
        var url = "https://apis.roblox.com/toolbox-service/v1/marketplace/\(cat.rawValue)?num=30&includeOnlyVerifiedCreators=false"
        let k = keyword.trimmingCharacters(in: .whitespaces)
        if !k.isEmpty { url += "&keyword=" + (k.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "") }
        if let cursor { url += "&cursor=" + (cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "") }
        let j = try await json(url)
        let ids = (j["data"] as? [[String: Any]] ?? []).compactMap { ($0["id"] as? NSNumber)?.int64Value }
        let next = (j["nextPageCursor"] as? String).flatMap { $0.isEmpty || $0 == "null" ? nil : $0 }
        guard !ids.isEmpty else { return ([], next) }
        var items = try await details(ids)
        let thumbs = (try? await thumbnails(ids)) ?? [:]
        for i in items.indices { items[i].thumbnail = thumbs[items[i].id] }
        return (items, next)
    }

    static func details(_ ids: [Int64]) async throws -> [Item] {
        let j = try await json("https://apis.roblox.com/toolbox-service/v1/items/details?assetIds=" + ids.map(String.init).joined(separator: ","))
        return (j["data"] as? [[String: Any]] ?? []).compactMap { d in
            let asset = d["asset"] as? [String: Any] ?? [:]
            guard let id = (asset["id"] as? NSNumber)?.int64Value else { return nil }
            let creator = (d["creator"] as? [String: Any])?["name"] as? String ?? ""
            return Item(id: id, name: asset["name"] as? String ?? "Asset \(id)", creator: creator, thumbnail: nil)
        }
    }

    static func thumbnails(_ ids: [Int64]) async throws -> [Int64: URL] {
        let j = try await json("https://thumbnails.roblox.com/v1/assets?assetIds=" + ids.map(String.init).joined(separator: ",") + "&size=150x150&format=Png")
        var out: [Int64: URL] = [:]
        for d in j["data"] as? [[String: Any]] ?? [] {
            if let id = (d["targetId"] as? NSNumber)?.int64Value, let s = d["imageUrl"] as? String, let u = URL(string: s) { out[id] = u }
        }
        return out
    }

    // MARK: experiences & places

    struct Game: Identifiable { let id: Int64; let name: String; let rootPlaceId: Int64 }
    struct Place: Identifiable { let id: Int64; let name: String }

    static func userGames() async throws -> [Game] {
        let j = try await json("https://develop.roblox.com/v1/user/universes?isArchived=false&limit=50&sortOrder=Desc", authed: true)
        return (j["data"] as? [[String: Any]] ?? []).compactMap { d in
            guard let id = (d["id"] as? NSNumber)?.int64Value else { return nil }
            return Game(id: id, name: d["name"] as? String ?? "Experience", rootPlaceId: (d["rootPlaceId"] as? NSNumber)?.int64Value ?? 0)
        }
    }

    static func places(_ universe: Int64) async throws -> [Place] {
        let j = try await json("https://develop.roblox.com/v1/universes/\(universe)/places?limit=100", authed: true)
        return (j["data"] as? [[String: Any]] ?? []).compactMap { d in
            guard let id = (d["id"] as? NSNumber)?.int64Value else { return nil }
            return Place(id: id, name: d["name"] as? String ?? "Place")
        }
    }

    static func universeOf(_ placeId: Int64) async throws -> Int64 {
        let j = try await json("https://apis.roblox.com/universes/v1/places/\(placeId)/universe")
        return (j["universeId"] as? NSNumber)?.int64Value ?? 0
    }

    /// Download a place file (places are assets).
    static func downloadPlace(_ placeId: Int64) async throws -> Data {
        try await AssetCache.shared.download(placeId)
    }

    /// Save or publish a place (RobloxCloud.publish): Open Cloud API key first, then the sign-in session.
    static func publish(universe: Int64, place: Int64, bytes: Data, publish: Bool) async throws -> String {
        let u = universe != 0 ? universe : try await universeOf(place)
        guard u != 0 else { throw WebError(message: "Couldn't find which experience place \(place) belongs to.") }
        let url = "https://apis.roblox.com/universes/v1/\(u)/places/\(place)/versions?versionType=\(publish ? "Published" : "Saved")"
        var errors: [String] = []
        if let key = AccountStore.shared.apiKey {
            let (d, r) = try await request(url, method: "POST", body: bytes, contentType: "application/octet-stream", headers: ["x-api-key": key])
            if (200..<300).contains(r.statusCode) { return version(d) }
            errors.append("API key: HTTP \(r.statusCode)" + (r.statusCode == 401 || r.statusCode == 403 ? " (the key needs universe-places write permission for this experience)" : ""))
        }
        if AccountStore.shared.cookie != nil {
            let (d, r) = try await request(url, method: "POST", body: bytes, contentType: "application/octet-stream", authed: true)
            if (200..<300).contains(r.statusCode) { return version(d) }
            errors.append("Signed-in upload: HTTP \(r.statusCode)")
        }
        if AccountStore.shared.apiKey == nil {
            throw WebError(message: "Roblox only accepts place uploads with an Open Cloud API key. Add one in Settings → Account." +
                           (errors.isEmpty ? "" : "\n" + errors.joined(separator: "\n")))
        }
        throw WebError(message: errors.joined(separator: "\n"))
    }

    private static func version(_ d: Data) -> String {
        let j = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        return (j["versionNumber"] as? NSNumber).map { "version \($0)" } ?? "done"
    }
}
