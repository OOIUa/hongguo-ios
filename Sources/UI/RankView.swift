import SwiftUI

/// The website's public boards: 综合, 真人剧, 漫剧 and AI 剧. The next page loads as the list reaches its end.
struct RankView: View {
    @EnvironmentObject private var model: AppModel
    @State private var board = RankBoard.all
    @State private var entries: [RankEntry] = []
    @State private var page = 0
    @State private var totalPages = 0
    @State private var loading = false
    @State private var error: String?
    @State private var request: Task<Void, Never>?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Picker("榜单", selection: $board) { ForEach(RankBoard.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
                ForEach(entries) { entry in
                    NavigationLink { DetailView(drama: entry.drama) } label: { row(entry) }.buttonStyle(.plain)
                        .onAppear { if entry.id == entries.last?.id { loadMore() } }
                }
                if let error { FailureView(message: error) { self.error = nil; loadMore() } }
                if loading { ProgressView().frame(maxWidth: .infinity).padding(20) }
            }.padding(16)
        }
        .appBackground(model.appearance).navigationTitle("榜单").navigationBarTitleDisplayMode(.inline).secondaryPage()
        .onChange(of: board) { _, _ in reset() }
        .onAppear { if entries.isEmpty && !loading { reset() } }
        .onDisappear { request?.cancel(); loading = false }
    }

    private func row(_ entry: RankEntry) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(entry.rank > 0 ? String(entry.rank) : "–").font(.headline.monospacedDigit()).frame(width: 32)
                .foregroundStyle((1...3).contains(entry.rank) ? model.appearance.accent : model.appearance.muted)
            PosterView(drama: entry.drama).frame(width: 76)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.drama.title).font(.subheadline.weight(.semibold)).foregroundStyle(model.appearance.ink).lineLimit(2).multilineTextAlignment(.leading)
                let facts = [entry.heat, entry.drama.episodeCount > 0 ? "全 \(entry.drama.episodeCount) 集" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
                if !facts.isEmpty { Text(facts).font(.caption).foregroundStyle(model.appearance.accent).lineLimit(1) }
                if !entry.drama.summary.isEmpty { Text(entry.drama.summary).font(.caption).foregroundStyle(model.appearance.muted).lineLimit(2).multilineTextAlignment(.leading) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.contentShape(Rectangle())
    }

    private func reset() {
        request?.cancel(); entries = []; page = 0; totalPages = 0; error = nil; loading = false
        load(board: board, page: 1)
    }

    private func loadMore() {
        guard !loading, error == nil, page == 0 || page < totalPages else { return }
        load(board: board, page: page + 1)
    }

    private func load(board: RankBoard, page next: Int) {
        loading = true
        request = Task {
            do {
                let result = try await DramaAPI.shared.rank(board: board, page: next)
                try Task.checkCancellation()
                guard board == self.board else { return }
                let known = Set(entries.map(\.id))
                entries += result.entries.filter { !known.contains($0.id) }
                page = result.page; totalPages = result.totalPages; loading = false
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                loading = false; self.error = friendlyError(error)
            }
        }
    }
}
