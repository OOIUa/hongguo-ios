import Foundation

@main struct AccountMetadataSelfTest {
    static func main() async throws {
        func check(_ value: @autoclosure () -> Bool, _ label: String) throws {
            guard value() else { throw HGError.message("FAIL " + label) }
        }
        func drama(_ id: String, title: String = "剧集", cover: String = "", count: Int = 0) -> Drama {
            Drama(id: id, title: title, coverURL: cover, summary: "", episodeCount: count)
        }
        let id = "7702763145030290457"
        let good = drama(id, title: "已取得的剧名", cover: "https://p.example/known.jpg", count: 80)
        let placeholder = drama(id)
        let unchanged = try await AccountRules.enrichDramas([placeholder], previous: [good]) { _ in [:] }
        try check(unchanged == [good], "partial-refresh-retains-known-name-and-poster")

        let titleOnly = try await AccountRules.enrichDramas([placeholder], previous: [good]) { _ in
            ["data":[["book_id":id,"book_name":"新名称"]]]
        }
        try check(titleOnly[0].title == "新名称" && titleOnly[0].coverURL == good.coverURL && titleOnly[0].episodeCount == 80, "title-only-row-does-not-erase-poster")
        let coverOnly = try await AccountRules.enrichDramas([placeholder], previous: [good]) { _ in
            ["data":[["book_id":id,"thumb_url":"http:\\/\\/p.example\\/new.jpg"]]]
        }
        try check(coverOnly[0].title == good.title && coverOnly[0].coverURL == "https://p.example/new.jpg", "cover-only-row-and-escaped-http")
        let nested = AccountRules.metadataDrama(row: ["book_id":id,"video_data":["series_id":id]],
            video: ["series_id":id,"series_title":"嵌套剧名","series_cover":"//p.example/nested.jpg"])
        try check(nested?.title == "嵌套剧名" && nested?.coverURL == "https://p.example/nested.jpg", "nested-series-name-and-cover")
        let canonical = AccountRules.metadataDrama(row: ["book_id":id,"book_name":"作品名","title":"介绍文字","thumb_url":"javascript:bad"],video: ["title":"介绍文字"])
        try check(canonical?.title == "作品名" && canonical?.coverURL.isEmpty == true, "book-name-precedes-synopsis-and-unsafe-image-rejected")

        let other = drama("999", title: "其他作品", cover: "https://p.example/other.jpg")
        let scoped = try await AccountRules.enrichDramas([placeholder], previous: [good,other]) { _ in
            ["data":[["book_id":"999","book_name":"串错的作品","thumb_url":"https://p.example/wrong.jpg"]]]
        }
        try check(scoped == [good], "no-unrequested-row-or-removed-cache-entry")
        try check(AccountRules.mergingMetadata(good, update: other) == good, "different-id-cannot-supply-metadata")

        let latest = LibraryEntry(drama: placeholder, episodeID: "802", episodeIndex: 12, position: 34, updatedAt: Date(timeIntervalSince1970: 200))
        let older = LibraryEntry(drama: good, episodeID: "801", episodeIndex: 2, position: 5, updatedAt: Date(timeIntervalSince1970: 100))
        let merged = AccountRules.mergingHistory([latest,older])
        try check(merged.count == 1 && merged[0].drama == good && merged[0].episodeID == latest.episodeID && merged[0].position == 34 && merged[0].episodeIndex == 12 && merged[0].updatedAt == latest.updatedAt,
                  "older-record-fills-metadata-without-rewinding-progress")

        let values = (1...120).map { drama(String($0)) }
        var batches = [[String]]()
        let pages = try await AccountRules.enrichDramas(values, previous: [drama("51", title: "缓存第51部")]) { ids in
            batches.append(ids)
            if batches.count == 2 { return [:] } // One failed optional metadata batch.
            return ["data":ids.map { ["book_id":$0,"book_name":"第\($0)部"] }]
        }
        try check(batches.map(\.count) == [50,50,20] && pages.map(\.id) == values.map(\.id), "all-lists-use-bounded-50-id-batches-and-keep-order")
        try check(pages[50].title == "缓存第51部" && pages[100].title == "第101部", "failed-batch-does-not-erase-cache-or-block-next-batch")
        let parsed = try ProtocolJSON.object(Data("{\"data\":[{\"book_id\":7702763145030290457,\"book_name\":\"长编号\"}]}".utf8))
        let longID = try await AccountRules.enrichDramas([placeholder], previous: []) { _ in parsed }
        try check(longID[0].id == id && longID[0].title == "长编号", "nineteen-digit-id-remains-exact")

        var calls = 0
        let task = Task {
            try await AccountRules.enrichDramas(values, previous: []) { _ in
                calls += 1; withUnsafeCurrentTask { $0?.cancel() }; return [:]
            }
        }
        do { _ = try await task.value; throw HGError.message("FAIL cancelled-enrichment-returned") } catch is CancellationError { }
        try check(calls == 1, "cancelled-enrichment-stops-following-batches")
        print("PASS account metadata: partial refresh, field merging, nested/flat fields, URLs, history progress, 50-id batches, scoped IDs and cancellation")
    }
}
