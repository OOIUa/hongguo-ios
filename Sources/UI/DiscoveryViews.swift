import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var account = AccountService.shared
    @StateObject private var loader = CatalogLoader()
    @State private var feed = "guess"
    @State private var guessPager: GuessPager?
    private let feeds = [("guess", "推荐"), ("recommend", "热度精选"), ("latest", "最新短剧"), ("comic", "漫剧榜单")]

    var body: some View {
        Group {
            if model.appearance == .immersive {
                ImmersiveFeed(loader: loader, feed: $feed, feeds: [("guess", "推荐"), ("recommend", "热度"), ("latest", "最新"), ("comic", "漫剧")],
                              load: { load(reset: $0) }).toolbar(.hidden, for: .navigationBar)
            } else {
                classicHome.appBackground(model.appearance).tabRoot(model.appearance)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { if loader.dramas.isEmpty { load(reset: true) } }
        .onChange(of: feed) { _, _ in load(reset: true) }
        // Login, logout or switching account changes whose feed 猜你喜欢 shows.
        .onChange(of: account.guessOwner) { _, _ in if feed == "guess" { load(reset: true) } }
    }

    private var refreshButton: some View {
        Button { load(reset: true) } label: { HeaderIcon(symbol: "arrow.clockwise") }.buttonStyle(.plain).accessibilityLabel("刷新首页")
    }

    private var classicHome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    Image("BrandLogo").resizable().scaledToFit().frame(width: 40, height: 40).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) { Text("红果剧场").font(.title2.bold()).foregroundStyle(model.appearance.ink); Text("好故事，随时接着看").font(.caption).foregroundStyle(model.appearance.muted) }
                    Spacer()
                    refreshButton
                }
                SearchEntry()
                if let first = loader.dramas.first, model.appearance == .warm { featured(first) }
                if !library.history.isEmpty { continueWatching }
                feedSelector
                if model.appearance == .cards && !loader.dramas.isEmpty { ranking }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: model.appearance == .warm ? 104 : 145), spacing: 12)], alignment: .leading, spacing: 20) {
                    ForEach(loader.dramas) { drama in NavigationLink { DetailView(drama: drama) } label: { DramaPoster(drama: drama) }.buttonStyle(.plain) }
                }
                if loader.dramas.isEmpty && !loader.isLoading && loader.error == nil { EmptyStateView(symbol: "sparkles.tv", title: "这一页暂时没有剧集", message: "可以刷新，或切换上方的内容类型。") }
                LoadMoreView(loader: loader) { load(reset: loader.dramas.isEmpty) }
            }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
        }.refreshable { load(reset: true) }
    }

    private var feedSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) { ForEach(feeds, id: \.0) { value, name in ChoiceChip(title: name, selected: feed == value) { feed = value } } }
        }
    }

    private func featured(_ drama: Drama) -> some View {
        NavigationLink { DetailView(drama: drama) } label: {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: URL(string: drama.coverURL)) { image in image.resizable().scaledToFill() } placeholder: { model.appearance.soft }
                    .frame(height: 210).frame(maxWidth: .infinity).clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.86)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 7) {
                    Text("今日推荐").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                    Text(drama.title).font(.title3.bold()).foregroundStyle(.white).lineLimit(2)
                    HStack { Text(drama.episodeCount > 0 ? "全 \(drama.episodeCount) 集" : "精彩短剧").font(.caption).foregroundStyle(.white.opacity(0.8)); Spacer(); Button { model.play(drama) } label: { Label("立即播放", systemImage: "play.fill").font(.caption.bold()).padding(.horizontal, 13).padding(.vertical, 10).background(.white, in: Capsule()).foregroundStyle(Color(hex: 0xA9341F)) }.buttonStyle(.plain) }
                }.padding(18)
            }.frame(height: 210).clipShape(RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain)
    }

    private var continueWatching: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { SectionHeading(title: "继续观看", subtitle: "本机"); Button("全部") { model.tab = 2 }.font(.caption).foregroundStyle(model.appearance.muted) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(library.history.prefix(8))) { entry in
                        Button { model.play(entry.drama) } label: {
                            HStack(spacing: 11) {
                                PosterView(drama: entry.drama, ratio: 0.8).frame(width: 57)
                                VStack(alignment: .leading, spacing: 7) { Text(entry.drama.title).font(.subheadline.weight(.semibold)).foregroundStyle(model.appearance.ink).lineLimit(2); Text("第 \(entry.episodeIndex) 集 · \(timeLabel(entry.position))").font(.caption).foregroundStyle(model.appearance.muted); Label("接着看", systemImage: "play.fill").font(.caption.weight(.semibold)).foregroundStyle(model.appearance.accent) }.frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(12).frame(width: 264).background(model.appearance.surface, in: RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var ranking: some View {
        VStack(alignment: .leading, spacing: 13) {
            SectionHeading(title: feed == "guess" ? "为你推荐" : "热度榜", subtitle: feed == "guess" ? "猜你喜欢" : "大家都在追")
            ForEach(Array(loader.dramas.prefix(3).enumerated()), id: \.element.id) { index, drama in
                NavigationLink { DetailView(drama: drama) } label: { HStack(spacing: 12) { Text("\(index + 1)").font(.title2.bold().italic()).foregroundStyle(model.appearance.accent).frame(width: 24); Text(drama.title).font(.subheadline.weight(.medium)).foregroundStyle(model.appearance.ink).lineLimit(1); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(model.appearance.muted) }.frame(minHeight: 38).contentShape(Rectangle()) }.buttonStyle(.plain)
            }
        }.padding(16).background(model.appearance.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private func load(reset: Bool = false) {
        let selected = feed
        guard selected == "guess" else { loader.load(reset: reset) { try await DramaAPI.shared.home(feed: selected, offset: $0) }; return }
        // Signed in: the account's own feed; otherwise the anonymous one. A changed owner restarts the round.
        let owner = account.guessOwner
        let restart = reset || guessPager == nil || guessPager?.owner != owner
        if restart { guessPager = GuessPager(owner: owner) { cursor, offset in try await AccountService.shared.guessBatch(owner: owner, cursor: cursor, offset: offset) } }
        guard let pager = guessPager else { return }
        loader.load(reset: restart) { _ in try await pager.next() }
    }
}

/// 沉浸暗场首页：一屏一部，上下滑动切换（对齐 Android ImmersiveHome）。
private struct ImmersiveFeed: View {
    @ObservedObject var loader: CatalogLoader
    @Binding var feed: String
    let feeds: [(String, String)]
    let load: (Bool) -> Void
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: LibraryStore
    @State private var current: String?
    @StateObject private var preview = FeedPreview()
    @State private var visible = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { outer in
            let insets = outer.safeAreaInsets
            ZStack(alignment: .top) {
                Color.black
                if loader.dramas.isEmpty {
                    placeholder.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(loader.dramas.enumerated()), id: \.element.id) { index, drama in
                                ImmersivePage(drama: drama, index: index, insets: insets,
                                              roomy: outer.size.height + insets.top + insets.bottom >= 640, preview: preview)
                                    .frame(width: outer.size.width + insets.leading + insets.trailing,
                                           height: outer.size.height + insets.top + insets.bottom)
                                    .id(drama.id)
                            }
                        }.scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollIndicators(.hidden)
                    .scrollPosition(id: $current)
                    .ignoresSafeArea()
                    .accessibilityIdentifier("immersive_feed")
                    if isLast, let banner { endBanner(banner).padding(.top, insets.top + 64) }
                }
                topBar.padding(.top, insets.top)
            }.ignoresSafeArea()
        }
        .onChange(of: current) { _, _ in prefetch(); syncPreview() }
        .onChange(of: loader.dramas.first?.id) { _, _ in current = loader.dramas.first?.id; syncPreview() }
        // Only the visible, foreground feed plays: pushing a page, switching tab, opening the full player or
        // backgrounding releases the preview, and coming back starts the current page again.
        .onAppear { visible = true; syncPreview() }
        .onDisappear { visible = false; preview.stop() }
        .onChange(of: model.playback == nil) { _, _ in syncPreview() }
        .onChange(of: scenePhase) { _, _ in syncPreview() }
    }

    private func syncPreview() {
        guard visible, scenePhase == .active, model.playback == nil, loader.dramas.indices.contains(index) else { preview.stop(); return }
        preview.play(loader.dramas[index])
    }

    private var index: Int { current.flatMap { id in loader.dramas.firstIndex { $0.id == id } } ?? 0 }
    private var isLast: Bool { index >= loader.dramas.count - 1 }

    private func prefetch() {
        if index >= loader.dramas.count - 3 && loader.hasMore && loader.error == nil && !loader.isLoading { load(false) }
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            Button { load(true) } label: { Image(systemName: "arrow.clockwise").font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44) }
                .accessibilityLabel("刷新推荐")
            HStack(spacing: 16) {
                ForEach(feeds, id: \.0) { value, name in
                    let selected = feed == value
                    Button { feed = value } label: {
                        VStack(spacing: 4) {
                            Text(name).font(.system(size: selected ? 17 : 16, weight: selected ? .bold : .medium))
                                .foregroundStyle(.white.opacity(selected ? 1 : 0.7)).fixedSize()
                            Capsule().fill(selected ? Color.white : .clear).frame(width: 18, height: 3)
                        }.frame(minHeight: 44)
                    }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                }
            }.frame(maxWidth: .infinity)
            NavigationLink { SearchView() } label: { Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44) }
                .accessibilityLabel("搜索")
        }.foregroundStyle(.white).padding(.horizontal, 8).padding(.top, 2)
    }

    @ViewBuilder private var placeholder: some View {
        if loader.isLoading {
            HStack(spacing: 12) { ProgressView().tint(.white); Text("正在准备推荐…").font(.subheadline).foregroundStyle(.white.opacity(0.8)) }
        } else {
            VStack(spacing: 12) {
                Text(loader.error ?? "这一组暂时没有剧集").font(.subheadline).foregroundStyle(.white).multilineTextAlignment(.center)
                Button("重新加载") { load(true) }.buttonStyle(.bordered).tint(.white)
            }.padding(24)
        }
    }

    private var banner: (String, String?, () -> Void)? {
        if let error = loader.error { return (error, "重试", { load(false) }) }
        if loader.isLoading { return ("正在加载更多…", nil, {}) }
        if !loader.hasMore { return ("已经看到最后一部了", "刷新", { load(true) }) }
        return nil
    }

    private func endBanner(_ banner: (String, String?, () -> Void)) -> some View {
        HStack(spacing: 4) {
            Text(banner.0).font(.footnote).foregroundStyle(.white).lineLimit(2).padding(.vertical, 8)
            if let action = banner.1 { Button(action, action: banner.2).font(.footnote.weight(.semibold)).foregroundStyle(Color(hex: 0xFFC56B)) }
        }.padding(.leading, 16).padding(.trailing, banner.1 == nil ? 16 : 8).frame(minHeight: 40)
            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 20)).padding(.horizontal, 24)
    }
}

private struct ImmersivePage: View {
    let drama: Drama
    let index: Int
    let insets: EdgeInsets
    let roomy: Bool
    @ObservedObject var preview: FeedPreview
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // The cover only paints the page; a fill-scaled image must not widen the layout of the overlays.
            Color.black.overlay {
                AsyncImage(url: URL(string: drama.coverURL)) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else { LinearGradient(colors: [Color(hex: 0x3A2A26), Color(hex: 0x141416)], startPoint: .top, endPoint: .bottom) }
                }.opacity(active && preview.rendered ? 0 : 1)
            }.clipped()
            if active, let player = preview.player {
                PlayerLayerView(player: player) { preview.markRendered() }.opacity(preview.rendered ? 1 : 0)
            }
            if active && preview.player != nil {
                FeedGestureView(tap: preview.toggle, holdBegan: preview.beginHold, holdEnded: preview.endHold)
            } else if active && preview.failed {
                FeedGestureView(tap: { preview.play(drama) }, holdBegan: {}, holdEnded: {})
            }
            if active && preview.paused && !preview.ended {
                Image(systemName: "play.fill").font(.system(size: 54)).foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
            }
            if active && preview.holding {
                Label("2× 临时加速中", systemImage: "forward.fill").font(.caption.bold()).foregroundStyle(.white)
                    .padding(.horizontal, 13).padding(.vertical, 8).background(.black.opacity(0.5), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, insets.top + 64)
                    .allowsHitTesting(false).transition(.opacity)
            }
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom).frame(height: 180)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.88)], startPoint: .top, endPoint: .bottom).frame(height: 380)
            }.allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(drama.title).font(.system(size: 20, weight: .bold)).foregroundStyle(.white).lineLimit(2)
                        Text([active && preview.player != nil ? "第 1 集" : nil, drama.episodeCount > 0 ? "全 \(drama.episodeCount) 集" : nil].compactMap { $0 }.joined(separator: " · "))
                            .font(.footnote).foregroundStyle(.white.opacity(0.8))
                        if roomy && !drama.summary.isEmpty { Text(drama.summary).font(.footnote).foregroundStyle(.white.opacity(0.82)).lineLimit(2) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(spacing: roomy ? 14 : 4) {
                        let favorite = library.isFavorite(drama)
                        Button { library.toggleFavorite(drama) } label: { rail(favorite ? "star.fill" : "star", favorite ? "已追" : "追剧", tint: favorite ? Color(hex: 0xFFC56B) : .white) }
                            .accessibilityIdentifier("immersive_favorite_\(index)")
                        NavigationLink { DetailView(drama: drama) } label: { rail("square.grid.2x2", "选集") }.accessibilityIdentifier("immersive_episodes_\(index)")
                        if roomy { NavigationLink { DetailView(drama: drama) } label: { rail("info.circle", "详情") }.accessibilityIdentifier("immersive_detail_\(index)") }
                    }.buttonStyle(.plain)
                }
                // After episode 1 ends, the same button turns into 继续播放 for episode 2.
                let continues = continueEpisode != nil
                Button { playFull() } label: {
                    ZStack {
                        HStack(spacing: 6) {
                            if model.openingDramaID == drama.id { ProgressView().tint(.white) } else { Image(systemName: continues ? "forward.end.fill" : "play.fill") }
                            Text(continues ? "继续播放" : "立即播放").font(.system(size: 15, weight: .semibold))
                            if let next = continueEpisode { Text(verbatim: "· 第 \(next.index) 集").font(.system(size: 14)).foregroundStyle(.white.opacity(0.85)) }
                            else if drama.episodeCount > 0 { Text(verbatim: "· 全 \(drama.episodeCount) 集").font(.system(size: 14)).foregroundStyle(.white.opacity(0.75)) }
                        }.id(continues)
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .move(edge: .top).combined(with: .opacity)))
                    }.foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 48)
                        .background(continues ? Color(hex: 0xC94426) : Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .scaleEffect(continues ? 1.02 : 1)
                }.buttonStyle(.plain).padding(.trailing, 6).accessibilityIdentifier("immersive_play_\(index)")
                    .animation(.spring(response: 0.45, dampingFraction: 0.78), value: continues)
                if roomy { Text("上滑看下一部").font(.caption2).foregroundStyle(.white.opacity(0.55)).frame(maxWidth: .infinity) }
            }.padding(.leading, 16 + insets.leading).padding(.trailing, 10 + insets.trailing).padding(.bottom, 16 + insets.bottom)
        }.animation(.easeOut(duration: 0.2), value: preview.holding)
    }

    private var active: Bool { preview.dramaID == drama.id }
    private var continueEpisode: Episode? { active && preview.ended ? preview.detail?.episodes.dropFirst().first : nil }

    /// 立即播放 continues the preview in the full player from where it is; after episode 1 ends, 继续播放 opens episode 2.
    private func playFull() {
        if continueEpisode != nil, let detail = preview.detail {
            model.playback = PlaybackRequest(detail: detail, index: 1, position: 0, recordsLocalHistory: true)
        } else if active, let detail = preview.detail, !preview.ended {
            model.playback = PlaybackRequest(detail: detail, index: 0, position: preview.position, recordsLocalHistory: true)
        } else { model.play(drama) }
    }

    private func rail(_ symbol: String, _ label: String, tint: Color = .white) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(tint).frame(height: 32)
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
        }.frame(minWidth: 52, minHeight: 52).contentShape(Rectangle())
    }
}

struct DiscoverView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var loader = CatalogLoader()
    @State private var genre = "short_play"
    @State private var groups: [FilterGroup] = []
    @State private var selection: [String: String] = [:]
    @State private var draft: [String: String] = [:]
    @State private var filtersVisible = false
    @State private var filtersError: String?
    @State private var filtersLoading = false
    private let genres = [("short_play", "短剧"), ("comic_series", "漫剧"), ("ai_series", "AI 剧")]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                TabHeader(title: model.appearance == .immersive ? "剧场" : "发现")
                SearchEntry(title: "搜索剧名或关键词")
                HStack(spacing: 10) { ForEach(genres, id: \.0) { value, name in ChoiceChip(title: name, selected: genre == value) { genre = value } }; Spacer(minLength: 0) }
                Button { draft = selection; filtersVisible = true } label: {
                    HStack(spacing: 12) { Image(systemName: "slider.horizontal.3").font(.title3); VStack(alignment: .leading, spacing: 4) { Text("筛选条件").font(.subheadline.weight(.semibold)); Text(selection.isEmpty ? "按题材、排序等条件查找" : "已应用 \(selection.count) 项条件").font(.caption).foregroundStyle(model.appearance.muted) }; Spacer(); Text("筛选").font(.subheadline.weight(.medium)); Image(systemName: "chevron.down").font(.caption) }.foregroundStyle(model.appearance.ink).padding(17).background(model.appearance.surface, in: RoundedRectangle(cornerRadius: 17))
                }.buttonStyle(.plain)
                if model.appearance == .cards {
                    LazyVStack(spacing: 12) { ForEach(loader.dramas) { drama in DramaListRow(drama: drama) } }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: model.appearance == .immersive ? 100 : 140), spacing: 12)], spacing: 20) { ForEach(loader.dramas) { drama in NavigationLink { DetailView(drama: drama) } label: { DramaPoster(drama: drama) }.buttonStyle(.plain) } }
                }
                if loader.dramas.isEmpty && !loader.isLoading && loader.error == nil { EmptyStateView(symbol: "line.3.horizontal.decrease.circle", title: "没有符合条件的剧集", message: "试试减少筛选条件，或切换内容类型。") }
                LoadMoreView(loader: loader) { load(reset: loader.dramas.isEmpty) }
            }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 20)
        }.navigationTitle(model.appearance == .immersive ? "剧场" : "发现")
            .appBackground(model.appearance).tabRoot(model.appearance)
            .refreshable { load(reset: true) }
            .task(id: genre) { selection = [:]; draft = [:]; load(reset: true); await loadFilters() }
            .sheet(isPresented: $filtersVisible) { filterSheet }
    }

    private var filterSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 23) {
                    if filtersLoading { ProgressView("正在读取筛选条件…") }
                    if let filtersError { FailureView(message: filtersError) { Task { await loadFilters() } } }
                    ForEach(groups, id: \.id) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.name).font(.headline).foregroundStyle(model.appearance.ink)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ChoiceChip(title: "全部", selected: draft[group.id] == nil) { draft.removeValue(forKey: group.id) }
                                    ForEach(group.options.filter { !$0.id.isEmpty }, id: \.id) { option in ChoiceChip(title: option.name, selected: draft[group.id] == option.id) { if draft[group.id] == option.id { draft.removeValue(forKey: group.id) } else { draft[group.id] = option.id } } }
                                }
                            }
                        }
                    }
                    if groups.isEmpty && !filtersLoading && filtersError == nil { Text("当前类型暂无更多筛选条件。").foregroundStyle(model.appearance.muted) }
                }.padding(20)
            }.appBackground(model.appearance).navigationTitle("筛选").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { filtersVisible = false } } }
                .safeAreaInset(edge: .bottom) { HStack(spacing: 12) { Button("重置") { draft = [:] }.buttonStyle(.bordered).frame(maxWidth: .infinity); Button("查看结果") { selection = draft; filtersVisible = false; load(reset: true) }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity) }.tint(model.appearance.accent).controlSize(.large).padding().background(model.appearance.surface) }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    private func load(reset: Bool = false) { let kind = genre, filters = selection; loader.load(reset: reset) { try await DramaAPI.shared.browse(genre: kind, filters: filters, offset: $0) } }
    private func loadFilters() async {
        filtersLoading = true; filtersError = nil
        let selected = genre
        do { let result = try await DramaAPI.shared.filters(genre: selected); guard !Task.isCancelled, selected == genre else { return }; groups = result; filtersLoading = false }
        catch { guard !Task.isCancelled, selected == genre else { return }; filtersError = friendlyError(error); groups = []; filtersLoading = false }
    }
}

struct SearchView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var loader = CatalogLoader()
    @State private var query = ""
    @State private var submitted = ""
    @FocusState private var focused: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    HStack { Image(systemName: "magnifyingglass").foregroundStyle(model.appearance.muted); TextField("搜索剧名或关键词", text: $query).submitLabel(.search).focused($focused).onSubmit(submit); if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(model.appearance.muted) }.accessibilityLabel("清空搜索词") } }.padding(13).background(model.appearance.surface, in: RoundedRectangle(cornerRadius: 14))
                    Button("搜索", action: submit).font(.subheadline.bold()).disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).buttonStyle(.borderedProminent).tint(model.appearance.accent)
                }
                if submitted.isEmpty { EmptyStateView(symbol: "magnifyingglass", title: "寻找你的下一部好剧", message: "输入剧名或关键词，发现喜欢的故事。") }
                else {
                    SectionHeading(title: "“\(submitted)”的结果", subtitle: "\(loader.dramas.count) 部")
                    LazyVStack(spacing: 12) { ForEach(loader.dramas) { drama in DramaListRow(drama: drama) } }
                    if loader.dramas.isEmpty && !loader.isLoading && loader.error == nil { EmptyStateView(symbol: "doc.text.magnifyingglass", title: "没有找到相关短剧", message: "换一个关键词再试试。") }
                    LoadMoreView(loader: loader) { load(reset: loader.dramas.isEmpty) }
                }
            }.padding(20)
        }.navigationTitle("搜索").navigationBarTitleDisplayMode(.inline).appBackground(model.appearance).onDisappear { focused = false }
    }
    private func submit() { let value = query.trimmingCharacters(in: .whitespacesAndNewlines); guard !value.isEmpty else { return }; focused = false; submitted = value; load(reset: true) }
    private func load(reset: Bool = false) { let value = submitted; loader.load(reset: reset) { try await DramaAPI.shared.search(query: value, offset: $0) } }
}

struct DramaListRow: View {
    let drama: Drama
    @EnvironmentObject private var model: AppModel
    var body: some View {
        NavigationLink { DetailView(drama: drama) } label: {
            HStack(alignment: .top, spacing: 14) {
                PosterView(drama: drama).frame(width: 88)
                VStack(alignment: .leading, spacing: 9) {
                    Text(drama.title).font(.headline).foregroundStyle(model.appearance.ink).lineLimit(2)
                    if drama.episodeCount > 0 { Text("全 \(drama.episodeCount) 集").font(.caption).foregroundStyle(model.appearance.accent) }
                    Text(drama.summary.isEmpty ? "点开查看剧集，开启一段新故事。" : drama.summary).font(.caption).foregroundStyle(model.appearance.muted).lineLimit(3)
                    Label("查看选集", systemImage: "play.circle").font(.caption.weight(.semibold)).foregroundStyle(model.appearance.accent)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(12).background(model.appearance.surface, in: RoundedRectangle(cornerRadius: 17))
        }.buttonStyle(.plain)
    }
}
