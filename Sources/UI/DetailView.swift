import SwiftUI

struct DetailView: View {
    let drama: Drama
    var resume: LibraryEntry? = nil
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var account = AccountService.shared
    @State private var detail: DramaDetail?
    @State private var loading = false
    @State private var error: String?
    @State private var selected = 0
    @State private var showFullSummary = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 18) {
                    PosterView(drama: detail?.drama ?? drama).frame(width: 128).shadow(color: .black.opacity(0.08), radius: 12, y: 7)
                    VStack(alignment: .leading, spacing: 12) {
                        Text((detail?.drama ?? drama).title).font(.title2.bold()).foregroundStyle(model.appearance.ink).fixedSize(horizontal: false, vertical: true)
                        Text(detail.map { "全 \($0.episodes.count) 集" } ?? (drama.episodeCount > 0 ? "全 \(drama.episodeCount) 集" : "短剧")).font(.subheadline).foregroundStyle(model.appearance.muted)
                        Label("短剧 · 好故事", systemImage: "sparkles").font(.caption).foregroundStyle(model.appearance.accent)
                        Button { library.toggleFavorite(detail?.drama ?? drama) } label: { Label(library.isFavorite(drama) ? "已收藏" : "本机收藏", systemImage: library.isFavorite(drama) ? "star.fill" : "star").font(.subheadline.weight(.semibold)) }.buttonStyle(.bordered).tint(model.appearance.accent)
                        if account.authenticated {
                            Button { Task { if account.pendingFavorites.contains(drama.id) { await account.refresh() } else { await account.toggleFavorite(detail?.drama ?? drama) } } } label: { Label(account.pendingFavorites.contains(drama.id) ? "核对账号收藏" : (account.isFavorite(drama) ? "账号已收藏" : "账号收藏"), systemImage: "cloud").font(.caption.weight(.medium)) }.disabled(account.busy).foregroundStyle(model.appearance.accent)
                        } else { NavigationLink { AccountView() } label: { Label("登录账号收藏", systemImage: "cloud").font(.caption) }.foregroundStyle(model.appearance.muted) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                let summary = (detail?.drama ?? drama).summary
                if !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 12) { SectionHeading(title: "故事简介"); Text(summary).font(.subheadline).foregroundStyle(model.appearance.muted).lineSpacing(5).lineLimit(showFullSummary ? nil : 4); if summary.count > 90 { Button(showFullSummary ? "收起" : "展开全部") { showFullSummary.toggle() }.font(.caption.weight(.semibold)).foregroundStyle(model.appearance.accent) } }
                        .padding(18).background(model.appearance.surface, in: RoundedRectangle(cornerRadius: 18))
                }
                if loading { ProgressView("正在获取完整选集…").frame(maxWidth: .infinity).padding(30) }
                if let message = account.message { Text(message).font(.caption).foregroundStyle(model.appearance.muted) }
                if let error { FailureView(message: error) { Task { await load() } } }
                if let detail {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack { SectionHeading(title: "选集", subtitle: "共 \(detail.episodes.count) 集"); if let last = library.progress(for: drama.id) { Text("上次第 \(last.episodeIndex) 集").font(.caption).foregroundStyle(model.appearance.accent) } }
                        if detail.episodes.isEmpty { EmptyStateView(symbol: "film", title: "暂无可播放剧集", message: "可以稍后重试获取选集。") }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 47), spacing: 10)], spacing: 10) {
                            ForEach(Array(detail.episodes.enumerated()), id: \.element.id) { index, episode in
                                Button { selected = index; model.play(detail, index: index, resume: resume) } label: {
                                    Text("\(episode.index)").font(.subheadline.weight(selected == index ? .bold : .regular)).frame(maxWidth: .infinity).frame(height: 46)
                                        .foregroundStyle(selected == index ? .white : model.appearance.ink)
                                        .background(selected == index ? model.appearance.accent : model.appearance.surface, in: RoundedRectangle(cornerRadius: 11))
                                }.buttonStyle(.plain).accessibilityLabel("播放第 \(episode.index) 集")
                            }
                        }
                    }
                }
            }.padding(20).padding(.bottom, 12)
        }.appBackground(model.appearance).navigationTitle("剧集详情").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                if let detail, !detail.episodes.isEmpty {
                    Button { model.play(detail, index: selected, resume: resume) } label: { Label("播放第 \(detail.episodes[min(selected, detail.episodes.count - 1)].index) 集", systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity).frame(height: 52) }.buttonStyle(.borderedProminent).tint(model.appearance.accent).padding(.horizontal, 20).padding(.vertical, 12).background(model.appearance.background)
                }
            }
            .task(id: drama.id) { await load() }
    }

    private func load() async {
        loading = true; error = nil
        do {
            let loaded = try await DramaAPI.shared.detail(drama: drama)
            try Task.checkCancellation()
            detail = loaded
            if let entry = resume ?? library.progress(for: drama.id) { selected = loaded.episodes.firstIndex { $0.id == entry.episodeID } ?? loaded.episodes.firstIndex { $0.index == entry.episodeIndex } ?? 0 }
            loading = false
        } catch is CancellationError { }
        catch { loading = false; self.error = friendlyError(error) }
    }
}
