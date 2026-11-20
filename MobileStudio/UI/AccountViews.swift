import SwiftUI
import WebKit
import StudioCore

/// Settings (port of ui/SettingsDialog.kt + ui/AccountUi.kt): Roblox account, Open Cloud key,
/// editor preferences, about.
struct SettingsView: View {
    @ObservedObject var store: StudioStore
    @ObservedObject var account = AccountStore.shared
    @State private var keyDraft = ""
    @State private var showSignIn = false
    @State private var showAbout = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if account.isSignedIn {
                        LabeledContent("Signed in as", value: account.userName ?? "Roblox user")
                        Button("Sign Out", role: .destructive) {
                            Task { await RobloxWeb.logout(); account.signOut() }
                        }
                    } else {
                        Button("Sign In to Roblox…", systemImage: "person.crop.circle") { showSignIn = true }
                    }
                } header: { Text("Account") } footer: {
                    Text("Signing in lets the app download assets that need an account and list your experiences.")
                }
                Section {
                    SecureField("Open Cloud API key", text: $keyDraft)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    HStack {
                        Button("Save Key") { account.setApiKey(keyDraft) }.disabled(keyDraft.isEmpty)
                        Spacer()
                        if account.apiKey != nil { Button("Remove", role: .destructive) { account.setApiKey(nil); keyDraft = "" } }
                    }
                } header: { Text("Open Cloud") } footer: {
                    Text(account.apiKey == nil ? "Needed to save or publish places to Roblox. Create one at create.roblox.com → Open Cloud → API Keys with the universe-places write and asset read permissions."
                                               : "An API key is saved on this device (in the Keychain).")
                }
                Section("Editor") {
                    Toggle("Snap to Grid", isOn: $store.snapEnabled)
                    Picker("Move Snap", selection: $store.moveSnap) {
                        ForEach([0.1, 0.25, 0.5, 1, 2, 4] as [Float], id: \.self) { Text("\(String(format: "%g", $0)) studs").tag($0) }
                    }
                    Picker("Rotate Snap", selection: $store.rotSnapDegrees) {
                        ForEach([1, 5, 15, 45, 90] as [Float], id: \.self) { Text("\(Int($0))°").tag($0) }
                    }
                    Toggle("Select Inside Models", isOn: $store.selectInsideModels)
                }
                Section("Storage") {
                    Button("Clear Downloaded Assets", role: .destructive) { AssetCache.shared.clear(); store.showToast("Asset cache cleared") }
                }
                Section {
                    Button("About Mobile Studio") { showAbout = true }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showSignIn) { SignInView() }
            .alert("Mobile Studio", isPresented: $showAbout) { Button("OK") {} } message: {
                Text("An iOS port of the Mobile Studio Android app. Scripting runs on the open-source Luau VM.")
            }
        }
    }
}

/// Roblox sign-in in a web view; the session cookie is read from the web view's cookie store
/// (AccountUi.kt's WebView flow). The user types their own credentials on roblox.com.
struct SignInView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var status = "Sign in on roblox.com, then you'll return here automatically."

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text(status).font(.footnote).foregroundStyle(.secondary).padding(8)
                RobloxLoginWebView { cookie in
                    status = "Signed in, finishing…"
                    AccountStore.shared.setSession(cookie: cookie, userName: nil, userId: nil)
                    Task {
                        if let u = try? await RobloxWeb.currentUser() {
                            AccountStore.shared.setSession(cookie: cookie, userName: u.name, userId: u.id)
                        }
                        dismiss()
                    }
                }
            }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct RobloxLoginWebView: UIViewRepresentable {
    let onCookie: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCookie) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.load(URLRequest(url: URL(string: "https://www.roblox.com/login")!))
        return wv
    }
    func updateUIView(_ v: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onCookie: (String) -> Void
        var done = false
        init(_ f: @escaping (String) -> Void) { onCookie = f }
        func webView(_ wv: WKWebView, didFinish navigation: WKNavigation!) {
            wv.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.done, let c = cookies.first(where: { $0.name == ".ROBLOSECURITY" && $0.domain.contains("roblox.com") }) else { return }
                self.done = true
                DispatchQueue.main.async { self.onCookie(c.value) }
            }
        }
    }
}

/// Toolbox (port of ui/ToolboxPanel.kt): search the Creator Store and insert models, decals, meshes, audio.
struct ToolboxView: View {
    @ObservedObject var store: StudioStore
    @State private var query = ""
    @State private var category: RobloxWeb.Category = .models
    @State private var items: [RobloxWeb.Item] = []
    @State private var cursor: String?
    @State private var loading = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Category", selection: $category) {
                    ForEach(RobloxWeb.Category.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).padding(8)
                if let error { Text(error).font(.footnote).foregroundStyle(.red).padding(8) }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                        ForEach(items) { it in
                            Button { insert(it) } label: {
                                VStack(spacing: 4) {
                                    AsyncImage(url: it.thumbnail) { img in img.resizable().scaledToFit() } placeholder: {
                                        Color(.tertiarySystemFill)
                                    }
                                    .frame(width: 100, height: 100)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    Text(it.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                                    Text(it.creator).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                        if cursor != nil && !loading {
                            Button("More") { Task { await load(more: true) } }
                        }
                    }
                    .padding(10)
                    if loading { ProgressView().padding() }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .onSubmit(of: .search) { Task { await load(more: false) } }
            .onChange(of: category) { _, _ in Task { await load(more: false) } }
            .task { await load(more: false) }
            .navigationTitle("Toolbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func load(more: Bool) async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let (found, next) = try await RobloxWeb.search(query, category, cursor: more ? cursor : nil)
            items = more ? items + found : found
            cursor = next
        } catch { self.error = error.localizedDescription }
    }

    private func insert(_ it: RobloxWeb.Item) {
        switch category {
        case .models:
            store.showToast("Downloading \(it.name)…")
            Task {
                do {
                    let data = try await AssetCache.shared.download(it.id)
                    let doc = try RbxFile.read(data)
                    store.session.insertDocument(doc)
                    if let first = doc.roots.first {
                        let parts = ([first] + first.descendants()).filter { $0.isA("BasePart") }
                        if !parts.isEmpty { ModelMathApp.moveTo(parts, store.spawnPoint()) }
                    }
                    store.showToast("Inserted \(it.name)")
                    dismiss()
                } catch { self.error = "Couldn't insert: \(error.localizedDescription)" }
            }
        case .decals:
            let target = store.selection.first(where: { $0.isA("BasePart") })
            let d = InstanceFactory.create("Decal")
            d.set("Texture", .string("rbxassetid://\(it.id)"), notify: false)
            d.name = it.name
            if let t = target { store.session.undo.begin("Insert Decal"); try? store.session.reparent(d, t); store.session.undo.commit() }
            else { store.showToast("Select a part to put the decal on"); return }
            dismiss()
        case .meshes:
            let mp = store.session.insertObject("MeshPart", at: store.spawnPoint() + Vector3(0, 2, 0))
            mp.name = it.name
            mp.set("MeshId", .string("rbxassetid://\(it.id)"))
            dismiss()
        case .audio:
            let s = store.session.insertObject("Sound", into: store.model.workspace)
            s.name = it.name
            s.set("SoundId", .string("rbxassetid://\(it.id)"))
            dismiss()
        }
    }
}

/// Move a set of parts so their bottom-centre lands on `p`.
enum ModelMathApp {
    static func moveTo(_ parts: [Instance], _ p: Vector3) {
        var lo = Vector3(.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude), hi = -lo
        for q in parts {
            let cf = PartData.cframe(q), h = PartData.size(q) * 0.5
            lo = lo.min(cf.position - h); hi = hi.max(cf.position + h)
        }
        let delta = Vector3(p.x - (lo.x + hi.x) / 2, p.y - lo.y, p.z - (lo.z + hi.z) / 2)
        for q in parts { PartData.setCFrame(q, PartData.cframe(q) + delta) }
    }
}

/// Open a place from the user's Roblox experiences, or publish the current place to one
/// (port of the cloud parts of ui/StartScreen.kt + core/Studio publishing).
struct CloudPlacesView: View {
    enum Mode { case open, publish }
    @ObservedObject var store: StudioStore
    let mode: Mode
    @State private var games: [RobloxWeb.Game] = []
    @State private var places: [Int64: [RobloxWeb.Place]] = [:]
    @State private var placeIdText = ""
    @State private var busy = false
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Place ID", text: $placeIdText).keyboardType(.numberPad)
                        Button(mode == .open ? "Open" : "Publish") {
                            if let id = Int64(placeIdText) { act(universe: 0, place: id, name: "Place \(id)") }
                        }
                        .disabled(Int64(placeIdText) == nil || busy)
                    }
                } footer: { Text("Or pick one of your experiences below.") }
                if let message { Section { Text(message).font(.footnote) } }
                Section("Your Experiences") {
                    if !AccountStore.shared.isSignedIn { Text("Sign in (Settings → Account) to list your experiences.").foregroundStyle(.secondary) }
                    ForEach(games) { g in
                        DisclosureGroup(g.name) {
                            ForEach(places[g.id] ?? []) { p in
                                Button(p.name) { act(universe: g.id, place: p.id, name: p.name) }.disabled(busy)
                            }
                        }
                        .task { if places[g.id] == nil { places[g.id] = (try? await RobloxWeb.places(g.id)) ?? [] } }
                    }
                }
            }
            .overlay { if busy { ProgressView() } }
            .task {
                guard AccountStore.shared.isSignedIn else { return }
                do { games = try await RobloxWeb.userGames() } catch { message = error.localizedDescription }
            }
            .navigationTitle(mode == .open ? "Open from Roblox" : "Publish to Roblox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func act(universe: Int64, place: Int64, name: String) {
        busy = true; message = nil
        Task {
            defer { busy = false }
            do {
                switch mode {
                case .open:
                    let data = try await RobloxWeb.downloadPlace(place)
                    store.openData(data, name: name, cloud: (universe, place))
                    dismiss()
                case .publish:
                    let v = try await RobloxWeb.publish(universe: universe, place: place, bytes: store.placeData(), publish: true)
                    store.cloudPlace = (universe, place)
                    store.showToast("Published (\(v))")
                    dismiss()
                }
            } catch { message = error.localizedDescription }
        }
    }
}
