// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UIKit

struct UpdateView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var service = UpdateService.shared
    @State private var sharing: UpdateShareItem?
    @State private var copyMessage: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("当前版本", value: "\(service.currentVersion)（\(service.currentBuild)）")
                Picker("更新线路", selection: $service.route) {
                    ForEach(UpdateRoute.allCases) { route in Text(route.title).tag(route) }
                }.disabled(service.busy).accessibilityIdentifier("updates.route")
                Button { service.check() } label: {
                    HStack { Label("检查更新", systemImage: "arrow.clockwise"); Spacer(); if service.phase == .checking { ProgressView() } }
                }.disabled(service.busy).accessibilityIdentifier("updates.check")
                Text(service.message).font(.subheadline).foregroundStyle(service.phase == .failed ? Color.red : model.appearance.muted)
                    .accessibilityIdentifier("updates.status")
                if let route = service.usedRoute { Text("本次使用：\(route.title)").font(.caption).foregroundStyle(.secondary) }
                if service.phase == .checking { Button("取消检查", role: .cancel) { service.cancel() }.accessibilityIdentifier("updates.cancel") }
            } header: { Text("版本更新") } footer: {
                Text("手动检查后才读取更新说明。自动线路依次尝试官方 GitHub、gh-proxy 和 ghfast；手动线路使用所选服务。")
            }

            if let manifest = service.manifest {
                Section {
                    LabeledContent("版本", value: "\(manifest.version)（\(manifest.build)）")
                    LabeledContent("系统要求", value: "iOS \(manifest.minimumOSVersion) 及以上")
                    LabeledContent("安装包", value: ByteCountFormatter.string(fromByteCount: Int64(manifest.size), countStyle: .file))
                    if let date = UpdateRules.publicationDate(manifest.publishedAt) { LabeledContent("发布于", value: date.formatted(date: .abbreviated, time: .omitted)) }
                    ForEach(Array(manifest.releaseNotes.enumerated()), id: \.offset) { _, note in Text(note).font(.subheadline) }
                    if service.canDownload {
                        Button { service.download() } label: { Label("下载并校验 IPA", systemImage: "arrow.down.circle") }
                            .accessibilityIdentifier("updates.download")
                    }
                    if service.phase == .downloading {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: service.progress)
                            Text("\(ByteCountFormatter.string(fromByteCount: service.receivedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(manifest.size), countStyle: .file))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("取消下载", role: .cancel) { service.cancel() }.accessibilityIdentifier("updates.cancel")
                    }
                    if let file = service.verifiedFile {
                        Label("大小与 SHA-256 校验通过", systemImage: "checkmark.shield.fill").foregroundStyle(.green)
                        Button { sharing = UpdateShareItem(file: file) } label: { Label("导出 IPA 到全能签", systemImage: "square.and.arrow.up") }
                            .accessibilityIdentifier("updates.export")
                        Button("清理已下载的安装包", role: .destructive) { service.discardFile() }
                    }
                } header: { Text("更新内容") } footer: {
                    Text("此安装包未签名。导出后需使用你自己的签名在全能签中签名，再安装。若分享列表没有全能签，可先存储到“文件”再导入。")
                }
            }

            Section {
                ForEach([UpdateRoute.github, .ghProxy, .ghfast]) { route in
                    Button {
                        UIPasteboard.general.string = route.sourceURL.absoluteString
                        copyMessage = "已复制\(route.title)软件源地址，可在全能签中手动添加。"
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("复制\(route.title)源")
                                Text(route.sourceURL.absoluteString).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                            }
                            Spacer(minLength: 4); Image(systemName: "doc.on.doc")
                        }
                    }.accessibilityIdentifier("updates.copy.\(route.rawValue)")
                }
            } header: { Text("全能签软件源") } footer: {
                Text("复制地址后在全能签的软件源管理中添加。软件源与应用内下载都需要由你自行签名安装。")
            }
        }
        .scrollContentBackground(.hidden).appBackground(model.appearance).tint(model.appearance.accent)
        .navigationTitle("检查更新").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sharing) { UpdateShareSheet(file: $0.file) }
        .alert("软件源", isPresented: Binding(get: { copyMessage != nil }, set: { if !$0 { copyMessage = nil } })) {
            Button("好") { copyMessage = nil }
        } message: { Text(copyMessage ?? "") }
        .onChange(of: scenePhase) { _, phase in if phase == .background { service.cancel() } }
        .onDisappear { service.cancel() }
    }
}

private struct UpdateShareItem: Identifiable { let id = UUID(); let file: URL }
private struct UpdateShareSheet: UIViewControllerRepresentable {
    let file: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [file], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
