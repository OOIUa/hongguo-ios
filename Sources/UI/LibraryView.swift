import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: LibraryStore
    @State private var favorites = false
    @State private var editing = false
    /// A signed-in account's records come first; 本机 is one tap away.
    @State private var showLocal = false
    @ObservedObject private var account = AccountService.shared
    private var showsAccount: Bool { account.authenticated && !showLocal }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                TabHeader(title: model.appearance == .immersive ? "追剧" : "片单") {
                    if !showsAccount { LocalLibraryActions(favorites: favorites, editing: $editing) }
                }
                if account.authenticated {
                    Picker("片单来源", selection: $showLocal) { Text("红果账号").tag(false); Text("本机").tag(true) }.pickerStyle(.segmented)
                } else {
                HStack { Text("本机记录").font(.caption.weight(.semibold)).foregroundStyle(model.appearance.accent).padding(.horizontal, 12).padding(.vertical, 8).background(model.appearance.accent.opacity(0.1), in: Capsule()); Spacer(); NavigationLink { AccountView() } label: { Label("红果账号", systemImage: "cloud").font(.caption.weight(.medium)).foregroundStyle(model.appearance.muted) } }
                }
                if showsAccount {
                    AccountPosterLists()
                } else {
                Picker("片单类型", selection: $favorites) { Text("观看历史 · \(library.history.count)").tag(false); Text("本机收藏 · \(library.favorites.count)").tag(true) }.pickerStyle(.segmented)
                LocalLibraryGrid(favorites: favorites, editing: $editing)
                }
            }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 20)
        }.navigationTitle(model.appearance == .immersive ? "追剧" : "片单").appBackground(model.appearance).tabRoot(model.appearance)
            .onChange(of: showsAccount) { _, _ in editing = false }
    }
}

/// The device's own records, shared by 追剧/片单 and the pages opened from 我的.
struct LocalLibraryGrid: View {
    let favorites: Bool
    @Binding var editing: Bool
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: LibraryStore
    private var entries: [LibraryEntry] { favorites ? library.favorites : library.history }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
                if let error = library.storageError { FailureView(message: error) { library.reload() } }
                if entries.isEmpty && !library.storageLocked { EmptyStateView(symbol: favorites ? "star" : "clock.arrow.circlepath", title: favorites ? "把喜欢的故事留在这里" : "从一部好剧开始", message: favorites ? "在详情或播放器中添加本机收藏。" : "开始播放后，这里会记住看到哪一集。") }
                else {
                    LazyVGrid(columns: threePosterColumns, spacing: 18) { ForEach(entries) { entry in libraryCell(entry) } }
                }
                if !entries.isEmpty { Text("收藏与历史各最多保留 200 部，仅保存在这台设备。\n卸载应用会移除本机记录。").font(.caption).lineSpacing(4).foregroundStyle(model.appearance.muted).padding(.top, 12) }
        }
        .onChange(of: entries.isEmpty) { _, empty in if empty { editing = false } }
    }

    private func libraryCell(_ entry: LibraryEntry) -> some View {
        Button { model.play(entry.drama) } label: {
            LibraryPosterCell(drama: entry.drama, subtitle: entry.episodeIndex > 0 ? "第 \(entry.episodeIndex) 集 · \(timeLabel(entry.position))" : nil).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if editing {
                Button(role: .destructive) { if favorites { library.removeFavorite(id: entry.id) } else { library.removeHistory(id: entry.id) } } label: {
                    Image(systemName: "minus.circle.fill").font(.title3).symbolRenderingMode(.palette).foregroundStyle(.white, .red).frame(width: 44, height: 44)
                }.accessibilityLabel(favorites ? "取消收藏\(entry.drama.title)" : "删除\(entry.drama.title)的记录")
            }
        }
    }
}

/// 管理 and 清空 for a local list.
struct LocalLibraryActions: View {
    let favorites: Bool
    @Binding var editing: Bool
    @State private var confirmClear = false
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: LibraryStore
    private var entries: [LibraryEntry] { favorites ? library.favorites : library.history }

    var body: some View {
        HStack(spacing: 12) {
            if editing && !entries.isEmpty { Button("清空", role: .destructive) { confirmClear = true }.font(.subheadline.weight(.semibold)) }
            if !entries.isEmpty { Button(editing ? "完成" : "管理") { editing.toggle() }.font(.subheadline.weight(.semibold)).tint(model.appearance.accent) }
        }
        .alert(favorites ? "清空本机收藏？" : "清空观看历史？", isPresented: $confirmClear) { Button("确认清空", role: .destructive) { if favorites { library.clearFavorites() } else { library.clearHistory() }; editing = false }; Button("取消", role: .cancel) {} } message: { Text(favorites ? "观看历史将保留。" : "本机收藏将保留。") }
    }
}

/// 播放历史 opened from 我的 or 继续观看: a page of that tab, so going back returns there and the tab bar stays put.
/// A signed-in account's history comes first unless the entry was about this device's records.
struct PlayHistoryView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var account = AccountService.shared
    @State private var showLocal: Bool
    @State private var editing = false
    private var showsAccount: Bool { account.authenticated && !showLocal }

    init(startLocal: Bool = false) { _showLocal = State(initialValue: startLocal) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if account.authenticated {
                    Picker("历史来源", selection: $showLocal) { Text("红果账号").tag(false); Text("本机").tag(true) }.pickerStyle(.segmented)
                }
                if showsAccount { AccountPosterLists(historyOnly: true) }
                else { LocalLibraryGrid(favorites: false, editing: $editing) }
            }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 20)
        }
        .appBackground(model.appearance).navigationTitle("播放历史").navigationBarTitleDisplayMode(.inline).secondaryPage()
        .toolbar { ToolbarItem(placement: .topBarTrailing) { if !showsAccount { LocalLibraryActions(favorites: false, editing: $editing) } } }
        .onChange(of: showsAccount) { _, _ in editing = false }
    }
}

struct LocalFavoritesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing = false

    var body: some View {
        ScrollView {
            LocalLibraryGrid(favorites: true, editing: $editing).padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 20)
        }
        .appBackground(model.appearance).navigationTitle("本机收藏").navigationBarTitleDisplayMode(.inline).secondaryPage()
        .toolbar { ToolbarItem(placement: .topBarTrailing) { LocalLibraryActions(favorites: true, editing: $editing) } }
    }
}
