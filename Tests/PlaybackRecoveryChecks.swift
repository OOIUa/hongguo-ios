import Foundation

func playbackRecoveryChecks(resources: URL) async throws {
    final class Calls: @unchecked Sendable {
        var registered = 0, singles = 0, legacy = 0, publicReads = 0
        var identities: [RegisteredIdentity] = []
        var time: TimeInterval = 0
        func identity() -> RegisteredIdentity {
            registered += 1
            return RegisteredIdentity(deviceID: "71000000000000000\(registered)", installID: "72000000000000000\(registered)", cdid: "fixture-\(registered)", appDeviceCookie: "")
        }
    }
    let model: [String: Any] = ["fixture":true]
    let track = VideoTrack(url: URL(string: "https://v1.qznovelvod.com/recovery.mp4")!, spadeA: "", encrypted: false, definition: "720p")
    let unexpectedPublicRead: @Sendable () async throws -> VideoTrack = { fatalError("Unexpected public episode lookup") }
    let mobileAPI = DramaAPI(resourceDirectory: resources), mobileCalls = Calls()
    _ = try await mobileAPI.playbackTrack(pause: {}, identity: { mobileCalls.identity() },
        mobile: { _ in mobileCalls.singles += 1; return .model(model) },
        single: { _ in fatalError("Successful v5 must skip old single endpoint") },
        publicEpisode: unexpectedPublicRead,
        read: { _,_ in fatalError("Successful v5 must skip compatibility endpoints") }, use: { _ in track })
    precondition(mobileCalls.singles == 1)
    let mobileTrace = await mobileAPI.lastPlaybackTrace
    precondition(mobileTrace == "M=ok")
    let fallbackAPI = DramaAPI(resourceDirectory: resources), mobileFallback = Calls()
    _ = try await fallbackAPI.playbackTrack(pause: {}, identity: { mobileFallback.identity() },
        mobile: { _ in mobileFallback.singles += 1; return .empty },
        single: { _ in mobileFallback.legacy += 1; return .model(model) },
        read: { _,_ in fatalError("Old single recovery must precede compatibility endpoints") }, use: { _ in track })
    precondition(mobileFallback.singles == 2 && mobileFallback.legacy == 1 && mobileFallback.registered == 1)
    let refusedMobile = DramaAPI(resourceDirectory: resources)
    do {
        _ = try await refusedMobile.playbackTrack(identity: { mobileFallback.identity() },
            mobile: { _ in throw DramaAPI.PlaybackRefusal(http: 403) },
            single: { _ in fatalError("v5 refusal must stop old endpoint") },
            read: { _,_ in fatalError("v5 refusal must stop compatibility endpoints") }, use: { _ in track })
        fatalError("v5 refusal ignored")
    } catch is DramaAPI.PlaybackRefusal { }
    let modelPriority = DramaAPI(resourceDirectory: resources)
    do {
        _ = try await modelPriority.playbackTrack(identity: { mobileFallback.identity() }, mobile: { _ in .invalid },
            single: { _ in .model(model) }, publicEpisode: unexpectedPublicRead, read: { _,_ in throw HGError.message("transport marker") },
            use: { _ in throw HGError.message("model marker") })
        fatalError("Invalid model accepted")
    } catch { precondition(error.localizedDescription == "model marker") }
    let reuse = DramaAPI(resourceDirectory: resources), calls = Calls()
    // Each episode initially returns an empty body for that session.
    for _ in 0..<2 {
        let episode = Calls()
        _ = try await reuse.playbackTrack(pause: {}, identity: { calls.identity() }, mobile: { session in
            let firstRead = !episode.identities.contains(session)
            episode.identities.append(session)
            calls.identities.append(session)
            return firstRead ? .empty : .model(model)
        }, read: { _,_ in fatalError("Recovery must precede legacy routes") }, use: { _ in track })
        precondition(episode.identities.count == 2)
    }
    precondition(calls.registered == 1)
    precondition(calls.identities.allSatisfy { $0 == calls.identities[0] })

    let exhausted = DramaAPI(resourceDirectory: resources), finite = Calls()
    do {
        _ = try await exhausted.playbackTrack(routes: [], pause: {}, identity: { finite.identity() }, single: { _ in finite.singles += 1; return .empty },
            read: { _,_ in fatalError() }, use: { _ in fatalError() })
        fatalError("Persistent empty replies must fail")
    } catch { precondition(error.localizedDescription.contains("空响应")) }
    precondition(finite.singles == 2 && finite.registered == 1)

    let guest = Calls()
    let guestTrack = try await exhausted.playbackTrack(pause: {}, identity: { guest.identity() },
        tabV5: { _ in .empty }, mobile: { _ in .empty }, single: { _ in .empty },
        publicEpisode: {
            precondition(guest.legacy == DramaAPI.playbackRoutes.count)
            guest.publicReads += 1
            return track
        }, read: { _,_ in guest.legacy += 1; return .empty }, use: { _ in fatalError("No app model") })
    let guestTrace = await exhausted.lastPlaybackTrace
    precondition(guestTrack.url == track.url && guest.publicReads == 1 && guestTrace.hasSuffix(" W=ok"))

    let mixed = try await exhausted.playbackTrack(routes: [], pause: {}, identity: { guest.identity() },
        tabV5: { _ in throw URLError(.networkConnectionLost) }, single: { _ in .empty },
        publicEpisode: { guest.publicReads += 1; return track }, read: { _,_ in fatalError() }, use: { _ in fatalError() })
    precondition(mixed.url == track.url && guest.publicReads == 2)
    do {
        _ = try await exhausted.playbackTrack(routes: [], identity: { guest.identity() },
            tabV5: { _ in throw URLError(.networkConnectionLost) }, publicEpisode: unexpectedPublicRead,
            read: { _,_ in fatalError() }, use: { _ in fatalError() })
        fatalError("Transient errors alone triggered a public lookup")
    } catch let error as URLError { precondition(error.code == .networkConnectionLost) }
    do {
        _ = try await exhausted.playbackTrack(routes: [], pause: {}, identity: { guest.identity() },
            tabV5: { _ in throw URLError(.serverCertificateUntrusted) }, mobile: { _ in .empty },
            single: { _ in throw URLError(.timedOut) }, publicEpisode: unexpectedPublicRead,
            read: { _,_ in fatalError() }, use: { _ in fatalError() })
        fatalError("A late transient error masked a hard failure")
    } catch let error as URLError { precondition(error.code == .serverCertificateUntrusted) }
    let renewed = Calls()
    do {
        _ = try await exhausted.playbackTrack(routes: DramaAPI.playbackRoutes.filter(\.renewsIdentity),
            identity: {
                if renewed.registered > 0 { throw URLError(.cannotConnectToHost) }
                return renewed.identity()
            }, tabV5: { _ in .empty }, publicEpisode: unexpectedPublicRead,
            read: { _,_ in throw URLError(.networkConnectionLost) }, use: { _ in fatalError() })
        fatalError("Registration errors made guest playback eligible")
    } catch let error as URLError { precondition(error.code == .cannotConnectToHost) }

    let shortDeadline = ProcessInfo.processInfo.systemUptime + 0.55
    let reserved = try await DramaAPI.$playbackDeadline.withValue(shortDeadline) {
        try await DramaAPI.withPlaybackBudget(3) {
            try await exhausted.playbackTrack(routes: [DramaAPI.playbackRoutes[0]], identity: { guest.identity() },
                tabV5: { _ in .empty }, publicEpisode: {
                    precondition(DramaAPI.playbackDeadline == shortDeadline)
                    return track
                }, read: { _,_ in
                    guard let deadline = DramaAPI.playbackDeadline else { fatalError("Missing compatibility deadline") }
                    precondition(deadline < shortDeadline)
                    try await Task.sleep(for: .seconds(3))
                    fatalError("The in-flight optional read exhausted the episode budget")
                }, use: { _ in fatalError() })
        }
    }
    precondition(reserved.url == track.url)

    // An empty primary read can also spend the remaining lookup time in its own retry.
    let retry = Calls()
    let retryResult = try await DramaAPI.withPlaybackBudget(0.75) {
        try await exhausted.playbackTrack(routes: [], pause: {}, identity: { retry.identity() }, mobile: { _ in
            retry.singles += 1
            if retry.singles == 1 { return .empty }
            try await Task.sleep(for: .seconds(3))
            fatalError("The repeated model read consumed the guest window")
        }, publicEpisode: {
            retry.publicReads += 1
            return track
        }, read: { _,_ in fatalError() }, use: { _ in fatalError() })
    }
    precondition(retryResult.url == track.url && retry.singles == 2 && retry.publicReads == 1)

    do {
        _ = try await exhausted.playbackTrack(routes: [], pause: {}, identity: { guest.identity() },
            tabV5: { _ in .invalid }, single: { _ in .empty }, publicEpisode: unexpectedPublicRead,
            read: { _,_ in fatalError() }, use: { _ in fatalError() })
        fatalError("A malformed model triggered the public source")
    } catch { precondition(error.localizedDescription == "服务暂未返回当前分集片源") }
    do {
        _ = try await exhausted.playbackTrack(routes: [], identity: { guest.identity() }, publicEpisode: unexpectedPublicRead,
            read: { _,_ in fatalError() }, use: { _ in fatalError() })
        fatalError("Zero attempts were counted as empty responses")
    } catch { precondition(error.localizedDescription == "服务暂未返回当前分集片源") }
    for refusal in [DramaAPI.PlaybackRefusal(http: 401), .init(code: 1003), .init(retryAfterStatus: 200)] {
        do {
            _ = try await exhausted.playbackTrack(identity: { guest.identity() }, tabV5: { _ in throw refusal },
                mobile: { _ in fatalError("A refusal must stop app requests") }, publicEpisode: unexpectedPublicRead,
                read: { _,_ in fatalError() }, use: { _ in fatalError() })
            fatalError("The first app reader's refusal was ignored")
        } catch let error as DramaAPI.PlaybackRefusal { precondition(error.localizedDescription == refusal.localizedDescription) }
    }
    do {
        _ = try await exhausted.playbackTrack(routes: [], identity: { guest.identity() }, tabV5: { _ in .empty },
            publicEpisode: { throw HGError.message("guest lookup unavailable") }, read: { _,_ in fatalError() }, use: { _ in fatalError() })
        fatalError("Public episode lookup error was lost")
    } catch { precondition(error.localizedDescription == "guest lookup unavailable") }

    for status in [403,429] {
        let api = DramaAPI(resourceDirectory: resources), rejected = Calls()
        do {
            _ = try await api.playbackTrack(pause: {}, identity: { rejected.identity() }, single: { _ in
                rejected.singles += 1; throw DramaAPI.PlaybackRefusal(http: status)
            }, read: { _,_ in fatalError("Rejections must stop legacy requests") }, use: { _ in fatalError() })
            fatalError("HTTP refusal must fail")
        } catch let error as DramaAPI.PlaybackRefusal { precondition(error.localizedDescription.contains("\(status)")) }
        precondition(rejected.singles == 1 && rejected.registered == 1)
    }
    // A transient empty body or a request to wait must not discard last episode's session.
    for refusal in [DramaAPI.PlaybackRefusal(retryAfterStatus: 200), DramaAPI.PlaybackRefusal(http: 429)] {
        do {
            _ = try await reuse.playbackTrack(pause: {}, identity: { fatalError("Expected the previous session") },
                mobile: { _ in .empty }, single: { _ in .empty }, read: { _,_ in throw refusal }, use: { _ in track })
            fatalError("Backoff must stop playback recovery")
        } catch let error as DramaAPI.PlaybackRefusal { precondition(error.isBackoff) }
        _ = try await reuse.playbackTrack(identity: { fatalError("Backoff must preserve the session") },
            mobile: { session in precondition(session == calls.identities[0]); return .model(model) },
            read: { _,_ in fatalError("Usable episode should start immediately") }, use: { _ in track })
    }
    for code in [1003,101144,110001,110002] {
        do { try DramaAPI.checkPlaybackBusinessRejection(Data("{\"code\":\(code),\"data\":null}".utf8)); fatalError("Refusal was ignored") }
        catch let error as DramaAPI.PlaybackRefusal { precondition(error.localizedDescription.contains("\(code)")) }
    }

    let budgetAPI = DramaAPI(resourceDirectory: resources), budget = Calls()
    do {
        _ = try await budgetAPI.playbackTrack(budget: 1, now: { budget.time }, pause: { budget.time = 2 }, identity: { budget.identity() },
            single: { _ in budget.singles += 1; return .empty }, publicEpisode: unexpectedPublicRead,
            read: { _,_ in fatalError("Budget exhausted") }, use: { _ in fatalError() })
        fatalError("Expired budget must fail")
    } catch let error as URLError { precondition(error.code == .timedOut) }
    precondition(budget.singles == 1 && budget.registered == 1)

    let cancelledAPI = DramaAPI(resourceDirectory: resources), cancelled = Calls()
    let task = Task {
        try await cancelledAPI.playbackTrack(pause: { withUnsafeCurrentTask { $0?.cancel() }; try Task.checkCancellation() },
            identity: { cancelled.identity() }, single: { _ in cancelled.singles += 1; return .empty },
            publicEpisode: unexpectedPublicRead,
            read: { _,_ in fatalError("Cancelled recovery must stop") }, use: { _ in fatalError() })
    }
    do { _ = try await task.value; fatalError("Cancellation ignored") } catch is CancellationError { }
    precondition(cancelled.registered == 1 && cancelled.singles == 1)

    // The actor is reentrant during network IO: an old failure must not clear a newer proven identity.
    let concurrentAPI = DramaAPI(resourceDirectory: resources), concurrent = Calls()
    _ = try await concurrentAPI.playbackTrack(identity: { concurrent.identity() }, single: { _ in .model(model) },
        read: { _,_ in fatalError() }, use: { _ in track })
    let entered = AsyncStream<Void>.makeStream(), release = AsyncStream<Void>.makeStream()
    let stale = Task {
        try await concurrentAPI.playbackTrack(identity: { fatalError("Should reuse the seed identity") }, single: { _ in
            entered.continuation.yield(())
            var iterator = release.stream.makeAsyncIterator(); _ = await iterator.next()
            throw DramaAPI.PlaybackRefusal(http: 403)
        }, read: { _,_ in fatalError() }, use: { _ in fatalError() })
    }
    var iterator = entered.stream.makeAsyncIterator(); _ = await iterator.next()
    do {
        _ = try await concurrentAPI.playbackTrack(identity: { fatalError("Should reuse the seed identity") },
            single: { _ in throw DramaAPI.PlaybackRefusal(http: 403) },
            read: { _,_ in fatalError() }, use: { _ in track })
        fatalError("Expected the seed session to be rejected")
    } catch is DramaAPI.PlaybackRefusal { }
    _ = try await concurrentAPI.playbackTrack(identity: { concurrent.identity() }, single: { identity in
        concurrent.identities.append(identity)
        return .model(model)
    }, read: { _,_ in fatalError() }, use: { _ in track })
    release.continuation.yield(())
    do { _ = try await stale.value; fatalError("Stale refusal ignored") } catch is DramaAPI.PlaybackRefusal { }
    _ = try await concurrentAPI.playbackTrack(identity: { fatalError("Stale request evicted the new identity") }, single: { identity in
        precondition(identity == concurrent.identities.last); return .model(model)
    }, read: { _,_ in fatalError() }, use: { _ in track })
    precondition(concurrent.registered == 2)
    entered.continuation.finish(); release.continuation.finish()
    print("PASS playback recovery: same-session retries, guest playback after empty app replies, refusals, budget, cancellation and stale concurrent failure")
}
