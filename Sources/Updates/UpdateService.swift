// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Combine

@MainActor
final class UpdateService: ObservableObject {
    static let shared = UpdateService()
    enum Phase { case idle, checking, current, available, unsupported, downloading, ready, failed }
    @Published var route: UpdateRoute {
        didSet { UserDefaults.standard.set(route.rawValue, forKey: "updates.route") }
    }
    @Published var checksOnLaunch: Bool {
        didSet { UserDefaults.standard.set(checksOnLaunch, forKey: "updates.checkOnLaunch") }
    }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var manifest: UpdateManifest?
    @Published private(set) var message = UpdateService.idleMessage
    private static let idleMessage = "点按“检查更新”获取最新版本。"
    @Published private(set) var progress: Double = 0
    @Published private(set) var receivedBytes: Int64 = 0
    @Published private(set) var verifiedFile: URL?
    @Published private(set) var usedRoute: UpdateRoute?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private let directory: URL
    let currentVersion: String
    let currentBuild: Int
    let systemVersion: String

    var busy: Bool { phase == .checking || phase == .downloading }
    var canDownload: Bool {
        guard let manifest else { return false }
        return !busy && verifiedFile == nil && UpdateRules.isNewer(version: manifest.version, build: manifest.build, currentVersion: currentVersion, currentBuild: currentBuild)
            && UpdateRules.supports(manifest.minimumOSVersion, systemVersion: systemVersion)
    }
    init(bundle: Bundle = .main) {
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        currentBuild = Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
        let version = ProcessInfo.processInfo.operatingSystemVersion
        systemVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        route = UpdateRoute(rawValue: UserDefaults.standard.string(forKey: "updates.route") ?? "automatic") ?? .automatic
        checksOnLaunch = UserDefaults.standard.object(forKey: "updates.checkOnLaunch") as? Bool ?? true
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("HongguoUpdates-v1", isDirectory: true)
        // The updater owns this folder; partial or previous-launch downloads are never offered as verified.
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }
    func check() {
        guard !busy else { return }
        discardFile()
        manifest = nil; usedRoute = nil; phase = .checking; message = "正在检查更新…"
        let ticket = UUID(); generation = ticket
        let routes = route.candidates
        operation = Task { [weak self] in
            guard let self else { return }
            var failure: Error = UpdateError.network
            for (index, line) in routes.enumerated() {
                guard !Task.isCancelled, ticket == self.generation else { return }
                if index > 0 { self.message = "上一条线路未完成检查，正在尝试\(line.title)…" }
                do {
                    let transfer = UpdateTransfer(address: line.manifestURL, target: .manifest)
                    guard case .manifest(let data) = try await transfer.run() else { throw UpdateError.invalidManifest }
                    let manifest = try UpdateRules.decode(data)
                    try Task.checkCancellation()
                    guard ticket == self.generation else { return }
                    self.manifest = manifest; self.usedRoute = line; self.operation = nil
                    if !UpdateRules.supports(manifest.minimumOSVersion, systemVersion: self.systemVersion) {
                        self.phase = .unsupported; self.message = "最新版本需要 iOS \(manifest.minimumOSVersion)，当前为 iOS \(self.systemVersion)。"
                    } else if UpdateRules.isNewer(version: manifest.version, build: manifest.build, currentVersion: self.currentVersion, currentBuild: self.currentBuild) {
                        self.phase = .available; self.message = "发现新版本 \(manifest.version)（\(manifest.build)）。"
                    } else { self.phase = .current; self.message = "当前已是最新版本。" }
                    return
                } catch is CancellationError { return }
                catch { failure = error }
            }
            guard ticket == self.generation else { return }
            self.phase = .failed; self.message = self.safeMessage(failure); self.operation = nil
        }
    }
    /// Quiet launch check: returns a newer, installable release the user has not ignored. Failures stay silent and leave the manual page idle.
    func checkOnLaunch() async -> UpdateManifest? {
        guard checksOnLaunch, phase == .idle else { return nil }
        check()
        await operation?.value
        guard phase == .available, let manifest else {
            if phase == .failed { phase = .idle; manifest = nil; usedRoute = nil; message = Self.idleMessage }
            return nil
        }
        return UserDefaults.standard.string(forKey: "updates.ignoredRelease") == Self.releaseKey(manifest) ? nil : manifest
    }
    /// Stops the launch prompt for this exact release; a manual check still offers it.
    func ignore(_ manifest: UpdateManifest) { UserDefaults.standard.set(Self.releaseKey(manifest), forKey: "updates.ignoredRelease") }
    private static func releaseKey(_ manifest: UpdateManifest) -> String { "\(manifest.version)+\(manifest.build)" }
    func download() {
        guard canDownload, let manifest else { return }
        discardFile()
        phase = .downloading; message = "正在下载并校验 IPA…"; progress = 0; receivedBytes = 0
        let ticket = UUID(); generation = ticket
        let routes = route.candidates
        operation = Task { [weak self] in
            guard let self else { return }
            var failure: Error = UpdateError.network
            do { try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true) }
            catch { self.phase = .failed; self.message = UpdateError.storage.localizedDescription; self.operation = nil; return }
            for (index, line) in routes.enumerated() {
                guard !Task.isCancelled, ticket == self.generation else { return }
                let destination = self.directory.appendingPathComponent(UUID().uuidString + ".ipa")
                self.progress = 0; self.receivedBytes = 0
                if index > 0 { self.message = "上一条线路未完成下载，正在尝试\(line.title)…" }
                do {
                    let transfer = UpdateTransfer(address: manifest.assetURL(for: line),
                        target: .ipa(destination: destination, official: manifest.officialURL, size: manifest.size, sha256: manifest.sha256)) { [weak self] received, total in
                        Task { @MainActor in
                            guard let self, ticket == self.generation else { return }
                            self.receivedBytes = received; self.progress = min(1, Double(received) / Double(max(1, total)))
                        }
                    }
                    guard case .ipa(let file) = try await transfer.run() else { throw UpdateError.invalidIPA }
                    do { try Task.checkCancellation() } catch { try? FileManager.default.removeItem(at: file); throw error }
                    guard ticket == self.generation else { try? FileManager.default.removeItem(at: file); return }
                    let readable = self.directory.appendingPathComponent("Hongguo-iOS-\(manifest.version)-\(manifest.build)-unsigned.ipa")
                    do { try FileManager.default.moveItem(at: file, to: readable) }
                    catch { try? FileManager.default.removeItem(at: file); throw UpdateError.storage }
                    self.verifiedFile = readable; self.usedRoute = line; self.progress = 1; self.phase = .ready
                    self.message = "安装包大小和 SHA-256 校验通过。请导出到全能签，使用你自己的签名后安装。"
                    self.operation = nil; return
                } catch is CancellationError { try? FileManager.default.removeItem(at: destination); return }
                catch { try? FileManager.default.removeItem(at: destination); failure = error }
            }
            guard ticket == self.generation else { return }
            self.phase = .failed; self.message = self.safeMessage(failure); self.operation = nil
        }
    }
    func cancel() {
        guard busy else { return }
        generation = UUID(); operation?.cancel(); operation = nil
        phase = manifest == nil ? .idle : .available
        progress = 0; receivedBytes = 0; message = "已取消。未完成的下载文件会被清理。"
    }
    func discardFile() {
        if let verifiedFile { try? FileManager.default.removeItem(at: verifiedFile) }
        verifiedFile = nil
        if phase == .ready { phase = .available; message = "已清理更新安装包。" }
    }
    private func safeMessage(_ error: Error) -> String { (error as? UpdateError)?.localizedDescription ?? UpdateError.network.localizedDescription }
}
