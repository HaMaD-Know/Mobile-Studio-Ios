import SwiftUI
import UIKit
import StudioCore

/// Dedicated Creator Store Audio tab (port of ui/AudioBrowser.kt):
/// Discover (Music / Sound Effects cards, Top charts, Genres, Vibes, Sound effects),
/// filter chips (Type, Sort, Length, Tag, Chart), paginated results, inline preview + seek bar.
struct AudioBrowserView: View {
    @ObservedObject var store: StudioStore
    @ObservedObject var audio: AudioEngine
    @Binding var query: String
    let searchTrigger: Int
    let onInsert: (RobloxWeb.AudioItem, Instance?) -> Void

    @State private var discover = true
    @State private var type: String? = nil          // nil, "Music", "SoundEffect"
    @State private var sort = "Relevance"
    @State private var lengthIdx = 0
    @State private var tag: String? = nil
    @State private var chart = "None"
    @State private var useLegacy = false

    @State private var items: [RobloxWeb.AudioItem] = []
    @State private var nextToken: String? = nil
    @State private var ended = false
    @State private var loading = false
    @State private var status: String = ""
    @State private var gen = 0
    @State private var draggingId: Int64? = nil
    @State private var dragPos: Float = 0

    private static let sorts: [(key: String, label: String)] = [
        ("Relevance", "Relevance"), ("Trending", "Trending"), ("Top", "Top rated"),
        ("UpdatedTime", "Most recent"), ("AudioDuration", "Length"),
    ]
    private static let lengths: [(label: String, min: Int, max: Int?)] = [
        ("Any length", 0, nil), ("Under 10s", 0, 10), ("10s – 1 min", 10, 60),
        ("1 – 3 min", 60, 180), ("Over 3 min", 180, nil),
    ]
    private static let charts: [(label: String, key: String)] = [
        ("Now", "Current"), ("This week", "Week"), ("This month", "Month"), ("This year", "Year"),
    ]
    private static let genres = [
        "Ambient", "Classical", "Country", "Electronic", "Funk", "Hip Hop", "Jazz", "Latin",
        "Lo-fi", "Metal", "Orchestral", "Pop", "R&B", "Reggae", "Rock", "Synthwave", "World",
    ]
    private static let vibes = [
        "Calm", "Chill", "Dark", "Epic", "Funny", "Happy", "Intense", "Mysterious",
        "Romantic", "Sad", "Scary", "Upbeat",
    ]
    private static let sfx = [
        "UI", "Footsteps", "Explosions", "Weapons", "Impacts", "Whooshes", "Magic", "Nature",
        "Ambience", "Vehicles", "Animals", "Voices", "Sci-fi", "Horror", "Cartoon", "Water",
        "Fire", "Doors", "Coins", "Alarms",
    ]

    init(store: StudioStore, query: Binding<String>, searchTrigger: Int,
         onInsert: @escaping (RobloxWeb.AudioItem, Instance?) -> Void) {
        self.store = store
        self.audio = store.audio
        self._query = query
        self.searchTrigger = searchTrigger
        self.onInsert = onInsert
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            if discover { discoverView } else { resultsView }
        }
        .onChange(of: searchTrigger) { _, _ in applySearch() }
        .onDisappear { audio.stopPreview() }
    }

    // MARK: filter chips

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chipButton("Discover", active: discover) {
                    type = nil; tag = nil; chart = "None"; query = ""; discover = true
                }
                Menu {
                    Button("All audio") { type = nil; runResults() }
                    Button("Music") { type = "Music"; runResults() }
                    Button("Sound Effects") { type = "SoundEffect"; runResults() }
                } label: {
                    chipLabel(type == "Music" ? "Music" : type == "SoundEffect" ? "Sound Effects" : "Type",
                              active: type != nil, dropdown: true)
                }
                Menu {
                    ForEach(Self.sorts, id: \.key) { s in
                        Button(s.label) { sort = s.key; runResults() }
                    }
                } label: {
                    let cur = Self.sorts.first { $0.key == sort }?.label ?? "Relevance"
                    chipLabel("Sort: \(cur)", active: sort != "Relevance", dropdown: true)
                }
                Menu {
                    ForEach(Array(Self.lengths.enumerated()), id: \.offset) { idx, l in
                        Button(l.label) { lengthIdx = idx; runResults() }
                    }
                } label: {
                    chipLabel(Self.lengths[lengthIdx].label, active: lengthIdx != 0, dropdown: true)
                }
                if let tag {
                    chipButton("\(tag)  ✕", active: true) {
                        self.tag = nil
                        applySearch()
                    }
                }
                if chart != "None" {
                    let lbl = Self.charts.first { $0.key == chart }?.label ?? chart
                    chipButton("Top charts: \(lbl)  ✕", active: true) {
                        chart = "None"
                        applySearch()
                    }
                }
            }
            .padding(.horizontal, 4).padding(.vertical, 4)
        }
    }

    private func chipButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(title, active: active, dropdown: false) }.buttonStyle(.plain)
    }

    private func chipLabel(_ title: String, active: Bool, dropdown: Bool) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 12, weight: active ? .semibold : .regular))
            if dropdown { Image(systemName: "chevron.down").font(.system(size: 9)) }
        }
        .foregroundStyle(active ? .white : Th.text)
        .padding(.horizontal, 10).frame(height: 26)
        .background(active ? Th.accent : Th.hover, in: Capsule())
    }

    // MARK: discover page

    private var discoverView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    categoryCard("Music", "Licensed tracks for your experience",
                                 color: Color(red: 0.48, green: 0.25, blue: 0.77)) {
                        type = "Music"; tag = nil; runResults()
                    }
                    categoryCard("Sound Effects", "UI, impacts, ambience and more",
                                 color: Color(red: 0.05, green: 0.56, blue: 0.56)) {
                        type = "SoundEffect"; tag = nil; runResults()
                    }
                }
                sectionTitle("Top charts")
                FlowChipsLayout(spacing: 6) {
                    ForEach(Self.charts, id: \.key) { c in
                        chipButton(c.label, active: false) {
                            chart = c.key; type = "Music"; tag = nil; runResults()
                        }
                    }
                }
                sectionTitle("Genres")
                FlowChipsLayout(spacing: 6) {
                    ForEach(Self.genres, id: \.self) { g in
                        chipButton(g, active: false) {
                            tag = g; type = "Music"; runResults()
                        }
                    }
                }
                sectionTitle("Vibes")
                FlowChipsLayout(spacing: 6) {
                    ForEach(Self.vibes, id: \.self) { v in
                        chipButton(v, active: false) {
                            tag = v; type = "Music"; runResults()
                        }
                    }
                }
                sectionTitle("Sound effects")
                FlowChipsLayout(spacing: 6) {
                    ForEach(Self.sfx, id: \.self) { s in
                        chipButton(s, active: false) {
                            tag = s; type = "SoundEffect"; runResults()
                        }
                    }
                }
                Text("Audio comes from the Roblox Creator Store. Previewing and playing audio needs a signed-in account (Roblox only serves audio files to signed-in users).")
                    .font(.system(size: 11)).foregroundStyle(Th.dim)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 4).padding(.vertical, 6)
        }
    }

    private func categoryCard(_ title: String, _ sub: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                Text(sub).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(LinearGradient(colors: [color, color.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.system(size: 13, weight: .semibold)).foregroundStyle(Th.text).padding(.top, 4)
    }

    // MARK: results list

    private var resultsView: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if !status.isEmpty {
                    Text(status).font(.system(size: 12)).foregroundStyle(Th.dim)
                        .multilineTextAlignment(.center).padding(16)
                }
                ForEach(items) { item in
                    audioRow(item)
                }
                if !ended && nextToken != nil && !loading {
                    Button { Task { await loadMore() } } label: {
                        Text("Load More").font(.system(size: 13, weight: .medium)).foregroundStyle(Th.text)
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(Th.hover, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 10)
                }
                if loading { ProgressView().padding(14) }
            }
            .padding(.vertical, 4)
        }
    }

    private func audioRow(_ item: RobloxWeb.AudioItem) -> some View {
        let pv = audio.preview?.id == item.id ? audio.preview : nil
        let isPlaying = pv?.state == .playing
        let isLoading = pv?.state == .loading
        let displayTitle = item.title.trimmingCharacters(in: .whitespaces).isEmpty ? item.name : item.title
        let typeLabel = item.type.localizedCaseInsensitiveContains("Music") ? "Music"
            : item.type.localizedCaseInsensitiveContains("Sound") ? "Sound effect" : ""
        let artistLabel = item.artist.trimmingCharacters(in: .whitespaces).isEmpty ? item.creator : item.artist
        let subParts = [artistLabel, typeLabel, item.album].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let subtitle: String = pv?.state == .error
            ? (pv?.error ?? "Can't play this audio")
            : subParts.joined(separator: "  ·  ")

        return VStack(spacing: 4) {
            HStack(spacing: 10) {
                Button { audio.togglePreview(id: item.id) } label: {
                    ZStack {
                        Circle().fill(isPlaying ? Th.accent : Th.hover).frame(width: 32, height: 32)
                        if isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 13)).foregroundStyle(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle).font(.system(size: 13, weight: .medium)).foregroundStyle(Th.text).lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 11))
                            .foregroundStyle(pv?.state == .error ? Th.error : Th.dim).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if item.seconds > 0 {
                    Text(Self.fmtTime(item.seconds)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Th.dim)
                }
                Button { onInsert(item, nil) } label: {
                    Text("Insert").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(Th.accent, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
            if let pv, pv.state != .error {
                let len = pv.length > 0 ? pv.length : Float(max(item.seconds, 1))
                let curPos = draggingId == item.id ? dragPos : pv.position
                HStack(spacing: 6) {
                    Text(Self.fmtClock(curPos)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Th.dim)
                    Slider(
                        value: Binding(
                            get: { Double(min(len, max(0, curPos))) },
                            set: { v in draggingId = item.id; dragPos = Float(v) }
                        ),
                        in: 0...Double(max(len, 0.1)),
                        onEditingChanged: { editing in
                            if !editing {
                                draggingId = nil
                                audio.seekPreview(id: item.id, seconds: dragPos)
                            }
                        }
                    )
                    .disabled(pv.length <= 0)
                    .tint(Th.accent)
                    Text(Self.fmtClock(len)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Th.dim)
                }
                .padding(.leading, 42)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
        .background(Th.card.opacity(pv != nil ? 0.85 : 0.4), in: RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            Button("Insert into Selection / Workspace") { onInsert(item, nil) }
            Button("Insert into SoundService") { onInsert(item, store.model.getService("SoundService")) }
            Button("Copy rbxassetid://\(item.id)") { UIPasteboard.general.string = "rbxassetid://\(item.id)" }
        }
    }

    // MARK: querying

    private func applySearch() {
        let kw = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if kw.isEmpty && tag == nil && chart == "None" && type == nil {
            discover = true
        } else {
            runResults()
        }
    }

    private func runResults() {
        discover = false
        gen += 1
        items = []
        nextToken = nil
        ended = false
        loading = false
        status = ""
        Task { await loadMore() }
    }

    private func buildQuery() -> RobloxWeb.AudioQuery {
        let len = Self.lengths[lengthIdx]
        let kw = [query.trimmingCharacters(in: .whitespacesAndNewlines), tag ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " ")
        return RobloxWeb.AudioQuery(keyword: kw, type: type, sort: sort,
                                    minSeconds: len.min, maxSeconds: len.max, chart: chart)
    }

    private func loadMore() async {
        guard !loading && !ended else { return }
        loading = true
        status = ""
        let curGen = gen
        let q = buildQuery()
        let tok = nextToken
        var page: RobloxWeb.AudioPage?
        var errMsg: String?
        do {
            if useLegacy {
                page = try await RobloxWeb.searchAudioLegacy(q.keyword, cursor: tok)
            } else {
                page = try await RobloxWeb.searchAudio(q, pageToken: tok)
            }
        } catch {
            errMsg = error.localizedDescription
            if !useLegacy {
                if let fallback = try? await RobloxWeb.searchAudioLegacy(q.keyword, cursor: tok) {
                    page = fallback
                    useLegacy = true
                }
            }
        }
        guard curGen == gen else { return }
        loading = false
        guard let page else {
            if items.isEmpty { status = "Couldn't reach the Creator Store.\n\(errMsg ?? "")" }
            return
        }
        items.append(contentsOf: page.items)
        nextToken = page.nextToken
        ended = page.nextToken == nil || page.items.isEmpty
        if items.isEmpty {
            status = "No audio found." + ((lengthIdx == 0 && type == nil) ? "" : "\nTry removing a filter.")
        }
    }

    private static func fmtTime(_ secs: Int) -> String {
        guard secs > 0 else { return "" }
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    private static func fmtClock(_ secs: Float) -> String {
        let s = max(0, Int(secs.rounded(.down)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Variable-width wrapping chip layout (SwiftUI counterpart of Android's FlowLayout).
private struct FlowChipsLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: maxW.isFinite ? maxW : x, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
