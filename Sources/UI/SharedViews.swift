import SwiftUI

struct PosterView: View {
    let drama: Drama
    var ratio: CGFloat = 0.72
    var body: some View {
        GeometryReader { geometry in
            AsyncImage(url: URL(string: drama.coverURL)) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else {
                    ZStack {
                        LinearGradient(colors: [Color(hex: 0xDDC3AF), Color(hex: 0x8E7062)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        VStack(spacing: 8) { Image(systemName: "film").font(.title); Text(drama.title).font(.caption).multilineTextAlignment(.center).lineLimit(3) }.foregroundStyle(.white.opacity(0.9)).padding(12)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .aspectRatio(ratio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .accessibilityHidden(true)
    }
}

struct DramaPoster: View {
    let drama: Drama
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            PosterView(drama: drama)
                .overlay(alignment: .bottomTrailing) {
                    if drama.episodeCount > 0 { Text("全 \(drama.episodeCount) 集").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 4).background(.black.opacity(0.62), in: Capsule()).padding(7) }
                }
            Text(drama.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(model.appearance.ink).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SearchEntry: View {
    var title = "搜索剧名，发现好故事"
    @EnvironmentObject private var model: AppModel
    var body: some View {
        NavigationLink { SearchView() } label: {
            HStack(spacing: 10) { Image(systemName: "magnifyingglass").font(.body.weight(.medium)); Text(title).font(.subheadline); Spacer(); Text("搜索").font(.caption.weight(.semibold)) }
                .foregroundStyle(model.appearance.muted).padding(.horizontal, 16).frame(minHeight: 48).background(model.appearance.soft, in: Capsule())
        }.buttonStyle(.plain).accessibilityLabel("搜索短剧")
    }
}

struct FailureView: View {
    let message: String
    let retry: () -> Void
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 27)).foregroundStyle(model.appearance.muted)
            Text(message).font(.subheadline).foregroundStyle(model.appearance.muted).multilineTextAlignment(.center).textSelection(.enabled)
            Button("重新加载", action: retry).buttonStyle(.borderedProminent).tint(model.appearance.accent)
        }.frame(maxWidth: .infinity).padding(24).background(model.appearance.surface, in: RoundedRectangle(cornerRadius: 18))
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 38, weight: .light)).foregroundStyle(model.appearance.accent.opacity(0.7))
            Text(title).font(.headline).foregroundStyle(model.appearance.ink)
            Text(message).font(.subheadline).foregroundStyle(model.appearance.muted).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 46).padding(.horizontal, 20)
    }
}

struct LoadMoreView: View {
    @ObservedObject var loader: CatalogLoader
    let action: () -> Void
    var body: some View {
        Group {
            if loader.isLoading { ProgressView("正在寻找好故事…").frame(maxWidth: .infinity).padding(20) }
            else if let error = loader.error { FailureView(message: error, retry: action) }
            else if loader.hasMore { Button("加载更多", action: action).buttonStyle(.bordered).frame(maxWidth: .infinity).padding(.vertical, 8) }
            else if !loader.dramas.isEmpty { Text("已经看到最后一部了").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(20) }
        }
    }
}

struct ChoiceChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(selected ? .semibold : .regular)).lineLimit(1)
                .foregroundStyle(selected ? model.appearance.accent : model.appearance.muted)
                .padding(.horizontal, 15).frame(minHeight: 42)
                .background(selected ? model.appearance.accent.opacity(0.1) : model.appearance.surface, in: Capsule())
                .overlay(Capsule().stroke(selected ? model.appearance.accent.opacity(0.35) : .clear, lineWidth: 1))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SectionHeading: View {
    let title: String
    var subtitle: String? = nil
    @EnvironmentObject private var model: AppModel
    var body: some View {
        HStack(alignment: .firstTextBaseline) { Text(title).font(.title3.bold()).foregroundStyle(model.appearance.ink); if let subtitle { Text(subtitle).font(.caption).foregroundStyle(model.appearance.muted) }; Spacer() }
    }
}

/// Compact in-content title row for tab roots, which hide the system navigation bar (its large title left a tall empty band).
struct TabHeader<Trailing: View>: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 12) { Text(title).font(.largeTitle.bold()).foregroundStyle(model.appearance.ink).accessibilityAddTraits(.isHeader); Spacer(minLength: 0); trailing }
    }
}
extension TabHeader where Trailing == EmptyView { init(title: String) { self.init(title: title) { EmptyView() } } }

struct HeaderIcon: View {
    @EnvironmentObject private var model: AppModel
    let symbol: String
    var body: some View { Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(model.appearance.accent).frame(width: 40, height: 40).background(model.appearance.surface, in: Circle()) }
}

extension View {
    func appBackground(_ theme: AppTheme) -> some View { self.background(theme.background.ignoresSafeArea()).toolbarBackground(theme.background, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar) }
    /// Pages pushed from 我的 (settings, account) cover the tab bar, like Android's full-screen settings.
    func secondaryPage() -> some View { self.toolbar(.hidden, for: .tabBar) }
    /// Tab roots draw their own header; a zero-height inset keeps scrolled content from showing under the status bar.
    func tabRoot(_ theme: AppTheme) -> some View {
        self.toolbar(.hidden, for: .navigationBar).safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 0).background(theme.background) }
    }
}
