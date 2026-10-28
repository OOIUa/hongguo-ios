// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit

enum UpdateTransferResult {
    case manifest(Data)
    case ipa(URL)
}

/// Streams to a bounded buffer or a private file. Uses a fresh cookie-free, credential-free foreground session.
final class UpdateTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Target {
        case manifest
        case ipa(destination: URL, official: URL, size: Int, sha256: String)
    }
    private let address: URL
    private let target: Target
    private let progress: @Sendable (Int64, Int64) -> Void
    private let testConfiguration: URLSessionConfiguration?
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false
    private var continuation: CheckedContinuation<UpdateTransferResult, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    // The following fields are confined to URLSession's serial delegate queue.
    private var received: Int64 = 0
    private var bytes = Data()
    private var header = Data()
    private var digest = SHA256()
    private var file: FileHandle?
    private var failure: Error?

    init(address: URL, target: Target, configuration: URLSessionConfiguration? = nil, progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) {
        self.address = address; self.target = target; self.progress = progress; self.testConfiguration = configuration
    }
    private var limit: Int64 {
        switch target { case .manifest: return Int64(UpdateRules.maximumManifestBytes); case .ipa(_, _, let size, _): return Int64(size) }
    }
    func run() async throws -> UpdateTransferResult {
        try Task.checkCancellation()
        switch target {
        case .manifest:
            guard [UpdateRoute.github, .ghProxy, .ghfast].contains(where: { $0.manifestURL.absoluteString == address.absoluteString }) else { throw UpdateError.invalidAddress }
        case .ipa(_, let official, let size, let hash):
            guard size > 0, size <= UpdateRules.maximumIPABytes, UpdateRules.validSHA256(hash) else { throw UpdateError.invalidManifest }
            guard UpdateRules.allowsAssetRedirect(address, initial: address, official: official) else { throw UpdateError.invalidAddress }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { completion in
                lock.lock()
                if cancelled { lock.unlock(); completion.resume(throwing: CancellationError()); return }
                continuation = completion
                let configuration = (testConfiguration?.copy() as? URLSessionConfiguration) ?? .ephemeral
                configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
                configuration.urlCredentialStorage = nil; configuration.urlCache = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForRequest = 25; configuration.timeoutIntervalForResource = 600
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                self.session = session
                var request = URLRequest(url: address, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
                request.httpShouldHandleCookies = false
                request.setValue("Hongguo-iOS-Updater/1", forHTTPHeaderField: "User-Agent")
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                request.setValue("application/json, application/octet-stream;q=0.9, */*;q=0.1", forHTTPHeaderField: "Accept")
                let task = session.dataTask(with: request); self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let next = request.url else { failure = UpdateError.invalidAddress; completionHandler(nil); return }
        let allowed: Bool
        switch target {
        case .manifest: allowed = UpdateRules.allowsManifestRedirect(next, initial: address)
        case .ipa(_, let official, _, _): allowed = UpdateRules.allowsAssetRedirect(next, initial: address, official: official)
        }
        guard allowed else { failure = UpdateError.invalidAddress; completionHandler(nil); return }
        var nextRequest = request
        nextRequest.httpShouldHandleCookies = false
        nextRequest.setValue(nil, forHTTPHeaderField: "Cookie")
        nextRequest.setValue(nil, forHTTPHeaderField: "Authorization")
        completionHandler(nextRequest)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            if failure == nil { failure = UpdateError.http((response as? HTTPURLResponse)?.statusCode ?? 0) }
            completionHandler(.cancel); return
        }
        if response.expectedContentLength > limit {
            failure = targetIsManifest ? UpdateError.manifestTooLarge : UpdateError.wrongSize
            completionHandler(.cancel); return
        }
        do {
            if case .ipa(let destination, _, _, _) = target {
                guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw UpdateError.storage }
                file = try FileHandle(forWritingTo: destination)
            }
            completionHandler(.allow)
        } catch { failure = UpdateError.storage; completionHandler(.cancel) }
    }
    private var targetIsManifest: Bool { if case .manifest = target { return true }; return false }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        received += Int64(data.count)
        guard received <= limit && received <= Int64(UpdateRules.maximumIPABytes) else {
            failure = targetIsManifest ? UpdateError.manifestTooLarge : UpdateError.wrongSize
            dataTask.cancel(); return
        }
        if targetIsManifest { bytes.append(data) }
        else {
            do {
                try file?.write(contentsOf: data)
                digest.update(data: data)
                if header.count < 4 { header.append(data.prefix(4 - header.count)) }
            } catch { failure = UpdateError.storage; dataTask.cancel(); return }
            progress(received, limit)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { finish(.failure(CancellationError())); return }
        if let failure { finish(.failure(failure)); return }
        if error != nil { finish(.failure(UpdateError.network)); return }
        switch target {
        case .manifest:
            finish(.success(.manifest(bytes)))
        case .ipa(let destination, _, let size, let expectedHash):
            guard received == Int64(size) else { finish(.failure(UpdateError.wrongSize)); return }
            let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == expectedHash.lowercased() else { finish(.failure(UpdateError.wrongDigest)); return }
            guard UpdateRules.hasZIPHeader(header) else { finish(.failure(UpdateError.invalidIPA)); return }
            do { try file?.synchronize(); try file?.close(); file = nil }
            catch { finish(.failure(UpdateError.storage)); return }
            finish(.success(.ipa(destination)))
        }
    }
    private func finish(_ result: Result<UpdateTransferResult, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; let completion = continuation; continuation = nil
        let session = session; self.session = nil; task = nil
        lock.unlock()
        try? file?.close(); file = nil
        if case .failure = result, case .ipa(let destination, _, _, _) = target { try? FileManager.default.removeItem(at: destination) }
        session?.finishTasksAndInvalidate()
        completion?.resume(with: result)
    }
}
