import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: LibraryStore
    @State private var favorites = false
    @State private var editing = false
    @State private var confirmClear = false
    private var entries: [LibraryEntry] { favorites ? library.favorites : library.history }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                TabHeader(title: model.appearance == .immersive ? "追剧" : "片单") {
                    if editing && !entries.isEmpty { Button("清空", role: .destructive) { confirmClear = true }.font(.subheadline.weight(.semibold)) }
                    if !entries.isEmpty { Button(editing ? "完成" : "管理") { editing.toggle() }.font(.subheadline.weight(.semibold)).tint(model.appearance.accent) }
                }
                HStack { Text("本机记录").font(.caption.weight(.semibold)).foregroundStyle(model.appearance.accent).padding(.horizontal, 12).padding(.vertical, 8).background(model.appearance.accent.opacity(0.1), in: Capsule()); Spacer(); NavigationLink { AccountView() } label: { Label("红果账号", systemImage: "cloud").font(.caption.weight(.medium)).foregroundStyle(model.appearance.muted) } }
                Picker("片单类型", selection: $favorites) { Text("观看历史 · \(library.history.count)").tag(false); Text("本机收藏 · \(library.favorites.count)").tag(true) }.pickerStyle(.segmented)
                if entries.isEmpty { EmptyStateView(symbol: favorites ? "star" : "clock.arrow.circlepath", title: favorites ? "把喜欢的故事留在这里" : "从一部好剧开始", message: favorites ? "在详情或播放器中添加本机收藏。" : "开始播放后，这里会记住看到哪一集。") }
                else if model.appearance == .cards && !editing {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 20) {
                        ForEach(entries) { entry in Button { model.play(entry.drama) } label: { VStack(alignment: .leading, spacing: 7) { DramaPoster(drama: entry.drama); if entry.episodeIndex > 0 { Text("第 \(entry.episodeIndex) 集 · \(timeLabel(entry.position))").font(.caption2).foregroundStyle(model.appearance.accent) } } }.buttonStyle(.plain) }
                    }
                } else {
                    LazyVStack(spacing: 12) { ForEach(entries) { entry in libraryRow(entry) } }
                }
                if !entries.isEmpty { Text("收藏与历史各最多保留 200 部，仅保存在这台设备。\n卸载应用会移除本机记录。").font(.caption).lineSpacing(4).foregroundStyle(model.appearance.muted).padding(.top, 12) }
            }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 20)
        }.navigationTitle(model.appearance == .immersive ? "追剧" : "片单").appBackground(model.appearance).tabRoot(model.appearance)
            .confirmationDialog(favorites ? "清空本机收藏？" : "清空观看历史？", isPresented: $confirmClear, titleVisibility: .visible) { Button("确认清空", role: .destructive) { if favorites { library.clearFavorites() } else { library.clearHistory() }; editing = false }; Button("取消", role: .cancel) {} } message: { Text(favorites ? "观看历史将保留。" : "本机收藏将保留。") }
            .onChange(of: entries.isEmpty) { _, empty in if empty { editing = false } }
    }

    private func libraryRow(_ entry: LibraryEntry) -> some View {
        HStack(spacing: 13) {
            Button { model.play(entry.drama) } label: {
                HStack(spacing: 13) {
                    PosterView(drama: entry.drama).frame(width: 65)
                    VStack(alignment: .leading, spacing: 8) { Text(entry.drama.title).font(.subheadline.weight(.semibold)).foregroundStyle(model.appearance.ink).lineLimit(2); Text(entry.episodeIndex > 0 ? "看到第 \(entry.episodeIndex) 集 · \(timeLabel(entry.position))" : "还未开始观看").font(.caption).foregroundStyle(model.appearance.muted); Label(entry.episodeIndex > 0 ? "继续观看" : "开始观看", systemImage: "play.fill").font(.caption.weight(.semibold)).foregroundStyle(model.appearance.accent) }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if editing { Button(role: .destructive) { if favorites { library.removeFavorite(id: entry.id) } else { library.removeHistory(id: entry.id) } } label: { Image(systemName: "minus.circle.fill").font(.title3).frame(width: 44, height: 44) }.accessibilityLabel("移除 \(entry.drama.title)") }
        }.padding(12).background(model.appearance.surface, in: RoundedRectangle(cornerRadius: 17))
    }
}
