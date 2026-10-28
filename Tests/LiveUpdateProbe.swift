// SPDX-License-Identifier: GPL-3.0-only
// Opt-in public release probe. Uses production URL, schema, streaming and SHA-256 verification.
import Foundation

@main struct LiveUpdateProbe {
    static func main() async throws {
        guard CommandLine.arguments.contains("--live") else {
            print("Run with --live to read the public update manifest and download one release IPA.")
            return
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hongguo-update-live-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var latest: UpdateManifest?
        var manifestRoute: UpdateRoute?
        for route in UpdateRoute.automatic.candidates {
            do {
                guard case .manifest(let bytes) = try await UpdateTransfer(address:route.manifestURL,target:.manifest).run() else { throw UpdateError.invalidManifest }
                latest = try UpdateRules.decode(bytes); manifestRoute = route; break
            } catch {
                let message = (error as? UpdateError)?.localizedDescription ?? "公开更新说明读取失败"
                print("Manifest route \(route.title): \(message)")
            }
        }
        guard let latest, let manifestRoute else { throw UpdateError.invalidManifest }
        var complete = false
        var downloadRoute: UpdateRoute?
        for route in UpdateRoute.automatic.candidates {
            let destination = folder.appendingPathComponent(UUID().uuidString + ".ipa")
            do {
                guard case .ipa(let file) = try await UpdateTransfer(address:latest.assetURL(for:route),
                    target:.ipa(destination:destination,official:latest.officialURL,size:latest.size,sha256:latest.sha256)).run() else { throw UpdateError.invalidIPA }
                let size = (try FileManager.default.attributesOfItem(atPath:file.path)[.size] as? NSNumber)?.intValue
                guard size == latest.size else { throw UpdateError.wrongSize }
                try FileManager.default.removeItem(at:file)
                guard !FileManager.default.fileExists(atPath:file.path) else { throw UpdateError.storage }
                complete = true; downloadRoute = route; break
            } catch {
                try? FileManager.default.removeItem(at:destination)
                let message = (error as? UpdateError)?.localizedDescription ?? "公开 IPA 下载验证失败"
                print("IPA route \(route.title): \(message)")
            }
        }
        guard complete, let downloadRoute else { throw UpdateError.network }
        try FileManager.default.removeItem(at:folder)
        guard !FileManager.default.fileExists(atPath:folder.path) else { throw UpdateError.storage }
        print("PASS live updates: \(latest.version) (\(latest.build)), manifest \(manifestRoute.title), IPA \(downloadRoute.title), \(latest.size) bytes, production size/SHA-256/ZIP checks passed, temporary files deleted.")
    }
}
