import Foundation

func playbackRecoveryChecks(resources: URL) async throws {
    final class Calls: @unchecked Sendable {
        var registered = 0, singles = 0, legacy = 0
        var identities: [RegisteredIdentity] = []
        var time: TimeInterval = 0
        func identity() -> RegisteredIdentity {
            registered += 1
            return RegisteredIdentity(deviceID: "71000000000000000\(registered)", installID: "72000000000000000\(registered)", cdid: "fixture-\(registered)", appDeviceCookie: "")
        }
    }
    let model: [String: Any] = ["fixture":true]
    let track = VideoTrack(url: URL(string: "https://v1.qznovelvod.com/recovery.mp4")!, spadeA: "", encrypted: false, definition: "720p")
    let mobileAPI = DramaAPI(resourceDirectory: resources), mobileCalls = Calls()
    _ = try await mobileAPI.playbackTrack(pause: {}, identity: { mobileCalls.identity() },
        mobile: { _ in mobileCalls.singles += 1; return .model(model) },
        single: { _ in fatalError("Successful v5 must skip old single endpoint") },
        read: { _,_ in fatalError("Successful v5 must skip compatibility endpoints") }, use: { _ in track })
    precondition(mobileCalls.singles == 1)
    let mobileTrace = await mobileAPI.lastPlaybackTrace
    precondition(mobileTrace == "M=ok")
    let fallbackAPI = DramaAPI(resourceDirectory: resources), mobileFallback = Calls()
    _ = try await fallbackAPI.playbackTrack(pause: {}, identity: { mobileFallback.identity() },
        mobile: { _ in mobileFallback.singles += 1; return .empty },
        single: { _ in mobileFallback.legacy += 1; return .model(model) },
        read: { _,_ in fatalError("Old single recovery must precede compatibility endpoints") }, use: { _ in track })
    precondition(mobileFallback.singles == 5 && mobileFallback.legacy == 1)
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
            single: { _ in .model(model) }, read: { _,_ in throw HGError.message("transport marker") },
            use: { _ in throw HGError.message("model marker") })
        fatalError("Invalid model accepted")
    } catch { precondition(error.localizedDescription == "model marker") }
    let reuse = DramaAPI(resourceDirectory: resources), calls = Calls()
    for _ in 0..<2 {
        _ = try await reuse.playbackTrack(pause: {}, identity: { calls.identity() }, single: {
            calls.singles += 1; calls.identities.append($0)
            if calls.singles == 1 { return .empty }
            return .model(model)
        }, read: { _,_ in fatalError("Recovery must precede legacy routes") }, use: { _ in track })
    }
    precondition(calls.registered == 2 && calls.singles == 3)
    precondition(calls.identities[0] != calls.identities[1] && calls.identities[1] == calls.identities[2])

    let exhausted = DramaAPI(resourceDirectory: resources), finite = Calls()
    do {
        _ = try await exhausted.playbackTrack(routes: [], pause: {}, identity: { finite.identity() }, single: { _ in finite.singles += 1; return .empty },
            read: { _,_ in fatalError() }, use: { _ in fatalError() })
        fatalError("Persistent empty replies must fail")
    } catch { precondition(error.localizedDescription.contains("空响应")) }
    precondition(finite.singles == 5 && finite.registered == 5)

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
    for code in [1003,101144,110001,110002] {
        do { try DramaAPI.checkPlaybackBusinessRejection(Data("{\"code\":\(code),\"data\":null}".utf8)); fatalError("Refusal was ignored") }
        catch let error as DramaAPI.PlaybackRefusal { precondition(error.localizedDescription.contains("\(code)")) }
    }

    let budgetAPI = DramaAPI(resourceDirectory: resources), budget = Calls()
    do {
        _ = try await budgetAPI.playbackTrack(budget: 1, now: { budget.time }, pause: { budget.time = 2 }, identity: { budget.identity() },
            single: { _ in budget.singles += 1; return .empty }, read: { _,_ in fatalError("Budget exhausted") }, use: { _ in fatalError() })
        fatalError("Expired budget must fail")
    } catch { precondition(error.localizedDescription.contains("空响应")) }
    precondition(budget.singles == 1 && budget.registered == 1)

    let cancelledAPI = DramaAPI(resourceDirectory: resources), cancelled = Calls()
    let task = Task {
        try await cancelledAPI.playbackTrack(pause: { withUnsafeCurrentTask { $0?.cancel() }; try Task.checkCancellation() },
            identity: { cancelled.identity() }, single: { _ in cancelled.singles += 1; return .empty },
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
    _ = try await concurrentAPI.playbackTrack(pause: {}, identity: { concurrent.identity() }, single: { identity in
        concurrent.singles += 1; concurrent.identities.append(identity)
        return concurrent.singles == 1 ? .empty : .model(model)
    }, read: { _,_ in fatalError() }, use: { _ in track })
    release.continuation.yield(())
    do { _ = try await stale.value; fatalError("Stale refusal ignored") } catch is DramaAPI.PlaybackRefusal { }
    _ = try await concurrentAPI.playbackTrack(identity: { fatalError("Stale request evicted the new identity") }, single: { identity in
        precondition(identity == concurrent.identities.last); return .model(model)
    }, read: { _,_ in fatalError() }, use: { _ in track })
    precondition(concurrent.registered == 2)
    entered.continuation.finish(); release.continuation.finish()
    print("PASS playback recovery: proven identity reuse, empty renewal, five-attempt cap, HTTP/business refusals, budget, cancellation and stale concurrent failure")
}
