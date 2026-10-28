import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var loader = CatalogLoader()
    @State private var feed = "recommend"
    private let feeds = [("recommend", "热度精选"), ("latest", "最新短剧"), ("comic", "漫剧榜单")]

    var body: some View {
        Group {
            if model.appearance == .immersive && !loader.dramas.isEmpty { immersiveHome }
            else { classicHome }
        }
        .navigationTitle(model.appearance == .immersive ? "红果剧场" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { load(reset: true) } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("刷新首页") } }
        .appBackground(model.appearance)
        .task { if loader.dramas.isEmpty { load(reset: true) } }
        .onChange(of: feed) { _, _ in load(reset: true) }
    }

    private var classicHome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    Text("果").font(.title2.weight(.black)).foregroundStyle(.white).frame(width: 40, height: 40).background(model.appearance.accent, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 2) { Text("红果剧场").font(.title2.bold()).foregroundStyle(model.appearance.ink); Text("好故事，随时接着看").font(.caption).foregroundStyle(model.appearance.muted) }
                    Spacer()
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
            }.padding(.horizontal, 20).padding(.bottom, 24)
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
            SectionHeading(title: "热度榜", subtitle: "大家都在追")
            ForEach(Array(loader.dramas.prefix(3).enumerated()), id: \.element.id) { index, drama in
                NavigationLink { DetailView(drama: drama) } label: { HStack(spacing: 12) { Text("\(index + 1)").font(.title2.bold().italic()).foregroundStyle(model.appearance.accent).frame(width: 24); Text(drama.title).font(.subheadline.weight(.medium)).foregroundStyle(model.appearance.ink).lineLimit(1); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(model.appearance.muted) }.frame(minHeight: 38) }.buttonStyle(.plain)
            }
        }.padding(16).background(model.appearance.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private var immersiveHome: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 16) {
                feedSelector.padding(.horizontal, 20)
                SearchEntry().padding(.horizontal, 20)
                ForEach(loader.dramas) { drama in
                    GeometryReader { geometry in
                        ZStack(alignment: .bottomLeading) {
                            PosterView(drama: drama).frame(width: geometry.size.width, height: geometry.size.height).clipped()
                            LinearGradient(colors: [.clear, .black.opacity(0.92)], startPoint: .center, endPoint: .bottom)
                            VStack(alignment: .leading, spacing: 12) {
                                NavigationLink { DetailView(drama: drama) } label: { Text(drama.title).font(.title.bold()).foregroundStyle(.white).lineLimit(2) }
                                Text(drama.summary).font(.subheadline).foregroundStyle(.white.opacity(0.78)).lineLimit(3)
                                HStack { Button { model.play(drama) } label: { Label("立即播放", systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity).padding(15).background(Color(hex: 0xC94426), in: Capsule()) }; Button { library.toggleFavorite(drama) } label: { Image(systemName: library.isFavorite(drama) ? "star.fill" : "star").font(.title2).padding(15).background(.white.opacity(0.15), in: Circle()) }.accessibilityLabel("本机收藏") }.foregroundStyle(.white).buttonStyle(.plain)
                            }.padding(23)
                        }.clipShape(RoundedRectangle(cornerRadius: 23))
                    }.frame(height: 540).padding(.horizontal, 16)
                }
                LoadMoreView(loader: loader) { load() }.padding(.horizontal, 20)
            }.padding(.bottom, 24)
        }.refreshable { load(reset: true) }
    }

    private func load(reset: Bool = false) { let selected = feed; loader.load(reset: reset) { try await DramaAPI.shared.home(feed: selected, offset: $0) } }
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
            }.padding(20)
        }.navigationTitle(model.appearance == .immersive ? "剧场" : "发现").navigationBarTitleDisplayMode(.large)
            .appBackground(model.appearance)
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
