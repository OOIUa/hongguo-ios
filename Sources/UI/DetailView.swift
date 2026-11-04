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
    @State private var related: [RelatedWork] = []
    @State private var reserving: RelatedWork?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 18) {
                    PosterView(drama: detail?.drama ?? drama).frame(width: 128).shadow(color: .black.opacity(0.08), radius: 12, y: 7)
                    VStack(alignment: .leading, spacing: 12) {
                        Text((detail?.drama ?? drama).title).font(.title2.bold()).foregroundStyle(model.appearance.ink).fixedSize(horizontal: false, vertical: true)
                        Text(detail.map { "全 \($0.episodes.count) 集" } ?? (drama.episodeCount > 0 ? "全 \(drama.episodeCount) 集" : "短剧")).font(.subheadline).foregroundStyle(model.appearance.muted)
                        Label("短剧 · 好故事", systemImage: "sparkles").font(.caption).foregroundStyle(model.appearance.accent)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                favoritePair
                let summary = (detail?.drama ?? drama).summary
                if !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 12) { SectionHeading(title: "故事简介"); Text(summary).font(.subheadline).foregroundStyle(model.appearance.muted).lineSpacing(5).lineLimit(showFullSummary ? nil : 4); if summary.count > 90 { Button(showFullSummary ? "收起" : "展开全部") { showFullSummary.toggle() }.font(.caption.weight(.semibold)).foregroundStyle(model.appearance.accent) } }
                        .padding(18).background(model.appearance.surface, in: RoundedRectangle(cornerRadius: 18))
                }
                if loading { ProgressView("正在获取完整选集…").frame(maxWidth: .infinity).padding(30) }
                if let message = account.message { Text(message).font(.caption).foregroundStyle(model.appearance.muted) }
                if let error { FailureView(message: error) { Task { await load() } } }
                if !related.isEmpty { relatedSection }
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
            // Secondary content: a failure leaves the section out without affecting the drama itself.
            .task(id: drama.id) { related = (try? await DramaAPI.shared.related(id: drama.id)) ?? [] }
            .alert("预约这部作品？", isPresented: Binding(get: { reserving != nil }, set: { if !$0 { reserving = nil } }), presenting: reserving) { work in
                Button("预约") { Task { await account.reserve(work) } }
                Button("取消", role: .cancel) { }
            } message: { work in Text("将在红果账号中预约《\(work.drama.title)》，上线后可在账号的预约列表查看。") }
    }

    /// The two favorites side by side, so where each one is kept is visible: this device or the Hongguo account.
    private var favoritePair: some View {
        HStack(spacing: 10) {
            Button { library.toggleFavorite(detail?.drama ?? drama) } label: {
                favoriteChip(symbol: "iphone", title: library.isFavorite(drama) ? "本机已收藏" : "本机收藏", caption: "仅存这台设备", selected: library.isFavorite(drama))
            }.buttonStyle(.plain)
            if account.authenticated {
                Button { Task { if account.pendingFavorites.contains(drama.id) { await account.refresh() } else { await account.toggleFavorite(detail?.drama ?? drama) } } } label: {
                    favoriteChip(symbol: account.isFavorite(drama) ? "checkmark.icloud" : "icloud", title: account.pendingFavorites.contains(drama.id) ? "核对账号收藏" : account.isFavorite(drama) ? "账号已收藏" : "账号收藏",
                                 caption: "同步红果账号", selected: account.isFavorite(drama))
                }.buttonStyle(.plain).disabled(account.busy)
            } else {
                NavigationLink { AccountView() } label: { favoriteChip(symbol: "icloud", title: "账号收藏", caption: "登录后同步", selected: false) }.buttonStyle(.plain)
            }
        }
    }

    private func favoriteChip(symbol: String, title: String, caption: String, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.body).foregroundStyle(selected ? model.appearance.accent : model.appearance.muted).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(selected ? model.appearance.accent : model.appearance.ink).lineLimit(1).minimumScaleFactor(0.85)
                Text(caption).font(.caption2).foregroundStyle(model.appearance.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 56)
        .background(model.appearance.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.appearance.accent, lineWidth: selected ? 1 : 0))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore).accessibilityLabel(title).accessibilityHint(caption).accessibilityAddTraits(.isButton)
    }

    /// Other seasons and same-IP works. An on-line work opens; an upcoming one can be reserved.
    private var relatedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "相关作品")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(related) { work in
                        if work.upcoming { relatedCard(work) }
                        else { NavigationLink { DetailView(drama: work.drama) } label: { relatedCard(work) }.buttonStyle(.plain) }
                    }
                }
            }
        }
    }

    private func relatedCard(_ work: RelatedWork) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            PosterView(drama: work.drama).frame(width: 96)
            Text(work.season.isEmpty ? "相关" : work.season).font(.caption).foregroundStyle(model.appearance.accent).lineLimit(1)
            Text(work.drama.title).font(.footnote).foregroundStyle(model.appearance.ink).lineLimit(2).multilineTextAlignment(.leading)
            if work.upcoming { reserveButton(work) }
            else { Text("全 \(work.drama.episodeCount) 集").font(.caption).foregroundStyle(model.appearance.muted).lineLimit(1) }
        }.frame(width: 96, alignment: .topLeading)
    }

    @ViewBuilder private func reserveButton(_ work: RelatedWork) -> some View {
        if account.isReserved(work.id) { Text("已预约").font(.caption.weight(.semibold)).foregroundStyle(model.appearance.muted).frame(minHeight: 32) }
        else if account.authenticated { Button("预约") { reserving = work }.font(.caption.weight(.semibold)).foregroundStyle(model.appearance.accent).frame(minHeight: 32).disabled(account.busy) }
        else { NavigationLink { AccountView() } label: { Text("登录后预约").font(.caption.weight(.semibold)).foregroundStyle(model.appearance.accent).frame(minHeight: 32) } }
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
