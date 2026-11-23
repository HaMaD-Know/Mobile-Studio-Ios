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

    static func userByName(_ name: String) async throws -> User? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let body = try JSONSerialization.data(withJSONObject: ["usernames": [trimmed], "excludeBannedUsers": true])
        let (d, r) = try await request("https://users.roblox.com/v1/usernames/users", method: "POST",
                                       body: body, contentType: "application/json")
        guard (200..<300).contains(r.statusCode) else { throw WebError(message: "HTTP \(r.statusCode)") }
        let j = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        guard let first = (j["data"] as? [[String: Any]])?.first,
              let id = (first["id"] as? NSNumber)?.int64Value else { return nil }
        return User(id: id, name: first["name"] as? String ?? trimmed,
                    displayName: first["displayName"] as? String ?? trimmed)
    }

    // MARK: universe avatar settings (RobloxCloud.avatarSettings / setAvatarSettings)

    struct AvatarSettings {
        var type: Int            // 0 = R6, 1 = R15, 2 = Player Choice
        var collision: Int?      // 0 = OuterBox, 1 = InnerBox
        var min: [String: Float]
        var max: [String: Float]
    }

    private static let avatarTypeNames: [String: Int] = ["MorphToR6": 0, "MorphToR15": 1, "PlayerChoice": 2]

    static func avatarSettings(universe: Int64) async throws -> AvatarSettings? {
        let j = try await json("https://develop.roblox.com/v1/universes/\(universe)/configuration", authed: true)
        guard let typeStr = j["universeAvatarType"] as? String,
              let type = avatarTypeNames[typeStr] else { return nil }
        let collStr = j["universeCollisionType"] as? String
        let collision: Int? = collStr == "OuterBox" ? 0 : (collStr == "InnerBox" ? 1 : nil)
        func scales(_ obj: Any?) -> [String: Float] {
            guard let dict = obj as? [String: Any] else { return [:] }
            var out: [String: Float] = [:]
            for (k, v) in dict { if let n = v as? NSNumber { out[k] = n.floatValue } }
            return out
        }
        return AvatarSettings(type: type, collision: collision,
                              min: scales(j["universeAvatarMinScales"]),
                              max: scales(j["universeAvatarMaxScales"]))
    }

    static func setAvatarSettings(universe: Int64, _ s: AvatarSettings) async throws {
        guard let typeStr = avatarTypeNames.first(where: { $0.value == s.type })?.key else { return }
        var obj: [String: Any] = ["universeAvatarType": typeStr]
        if let c = s.collision { obj["universeCollisionType"] = c == 1 ? "InnerBox" : "OuterBox" }
        if !s.min.isEmpty { obj["universeAvatarMinScales"] = s.min.mapValues { Double($0) } }
        if !s.max.isEmpty { obj["universeAvatarMaxScales"] = s.max.mapValues { Double($0) } }
        let body = try JSONSerialization.data(withJSONObject: obj)
        let (_, r) = try await request("https://develop.roblox.com/v2/universes/\(universe)/configuration",
                                       method: "PATCH", body: body, contentType: "application/json", authed: true)
        guard (200..<300).contains(r.statusCode) else { throw WebError(message: "HTTP \(r.statusCode)") }
    }

    // MARK: Toolbox

    enum Category: Int, CaseIterable, Identifiable {
        case models = 10, decals = 13, audio = 3, meshes = 40
        var id: Int { rawValue }
        var label: String {
            switch self { case .models: "Models"; case .decals: "Decals"; case .audio: "Audio"; case .meshes: "Meshes" }
        }
    }

    struct Item: Identifiable { let id: Int64; let name: String; let creator: String; var verified: Bool = false; var thumbnail: URL? }

    static func search(_ keyword: String, _ cat: Category, cursor: String? = nil, freeOnly: Bool = false) async throws -> ([Item], String?) {
        var url = "https://apis.roblox.com/toolbox-service/v1/marketplace/\(cat.rawValue)?num=30&includeOnlyVerifiedCreators=false"
        if freeOnly { url += "&minPrice=0&maxPrice=0" }
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
            let creatorObj = d["creator"] as? [String: Any]
            let creator = creatorObj?["name"] as? String ?? ""
            let verified = creatorObj?["isVerifiedCreator"] as? Bool ?? false
            return Item(id: id, name: asset["name"] as? String ?? "Asset \(id)", creator: creator, verified: verified, thumbnail: nil)
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

    // MARK: Audio catalog (RobloxApi.searchAudio / searchAudioLegacy)

    struct AudioQuery {
        var keyword: String = ""
        var type: String? = nil          // nil, "Music", "SoundEffect"
        var sort: String = "Relevance"   // Relevance, Trending, Top, UpdatedTime, AudioDuration
        var minSeconds: Int = 0
        var maxSeconds: Int? = nil
        var chart: String = "None"       // None, Current, Week, Month, Year
        var artist: String = ""
    }

    struct AudioItem: Identifiable {
        let id: Int64
        let name: String
        let artist: String
        let title: String
        let seconds: Int
        let type: String
        let creator: String
        let verified: Bool
        let album: String
    }

    struct AudioPage {
        let items: [AudioItem]
        let nextToken: String?
    }

    static func searchAudio(_ q: AudioQuery, pageToken: String? = nil, pageSize: Int = 30) async throws -> AudioPage {
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s }
        var url = "https://apis.roblox.com/toolbox-service/v2/assets:search?searchCategoryType=Audio&maxPageSize=\(pageSize)&includeOnlyVerifiedCreators=false"
        let kw = q.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !kw.isEmpty { url += "&query=" + enc(kw) }
        if let t = q.type { url += "&audioTypes=" + enc(t) }
        if q.sort != "Relevance" {
            let dir = q.sort == "AudioDuration" ? "Ascending" : "Descending"
            url += "&sortCategory=\(enc(q.sort))&sortDirection=\(dir)"
        }
        if q.minSeconds > 0 { url += "&audioMinDurationSeconds=\(q.minSeconds)" }
        if let mx = q.maxSeconds { url += "&audioMaxDurationSeconds=\(mx)" }
        if q.chart != "None" { url += "&musicChartType=\(enc(q.chart))&includeTopCharts=true" }
        let art = q.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !art.isEmpty { url += "&audioArtist=" + enc(art) }
        if let tok = pageToken { url += "&pageToken=" + enc(tok) }

        var headers: [String: String] = [:]
        if let c = AccountStore.shared.cookie, !c.isEmpty { headers["Cookie"] = ".ROBLOSECURITY=" + c }
        let (data, resp) = try await request(url, headers: headers)
        guard (200..<300).contains(resp.statusCode) else { throw WebError(message: "HTTP \(resp.statusCode)") }
        let j = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let arr = (j["creatorStoreAssets"] as? [[String: Any]])
            ?? (j["assets"] as? [[String: Any]])
            ?? (j["data"] as? [[String: Any]])
            ?? []
        var out: [AudioItem] = []
        for entry in arr {
            let asset = (entry["asset"] as? [String: Any]) ?? entry
            guard let id = (asset["id"] as? NSNumber)?.int64Value, id != 0 else { continue }
            let details = (asset["audioDetails"] as? [String: Any])
                ?? (asset["audio"] as? [String: Any])
                ?? asset
            let creatorObj = (entry["creator"] as? [String: Any]) ?? (asset["creator"] as? [String: Any])
            let seconds = (details["durationSeconds"] as? NSNumber)?.intValue
                ?? (details["duration"] as? NSNumber)?.intValue
                ?? (asset["durationSeconds"] as? NSNumber)?.intValue ?? 0
            let type = (details["audioType"] as? String)
                ?? (asset["audioType"] as? String)
                ?? (asset["assetSubType"] as? String) ?? ""
            let name = asset["name"] as? String ?? "Audio \(id)"
            let artist = (details["artist"] as? String) ?? (asset["artist"] as? String) ?? ""
            let title = (details["title"] as? String) ?? (asset["title"] as? String) ?? ""
            let creator = creatorObj?["name"] as? String ?? ""
            let verified = (creatorObj?["verified"] as? Bool == true) || (creatorObj?["isVerifiedCreator"] as? Bool == true)
            let album = (details["album"] as? String) ?? (asset["album"] as? String) ?? ""
            out.append(AudioItem(id: id, name: name, artist: artist, title: title, seconds: seconds,
                                 type: type, creator: creator, verified: verified, album: album))
        }
        let rawTok = j["nextPageToken"] as? String
        let next = rawTok.flatMap { $0.isEmpty || $0 == "null" ? nil : $0 }
        return AudioPage(items: out, nextToken: next)
    }

    static func searchAudioLegacy(_ keyword: String, cursor: String? = nil) async throws -> AudioPage {
        let (items, next) = try await search(keyword, .audio, cursor: cursor)
        let mapped = items.map {
            AudioItem(id: $0.id, name: $0.name, artist: $0.creator, title: $0.name,
                      seconds: 0, type: "", creator: $0.creator, verified: false, album: "")
        }
        return AudioPage(items: mapped, nextToken: next)
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
