import XCTest

@MainActor
final class HongguoQATests: XCTestCase {
    func testUpdateSourcesAndVersion() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.ooiua.hongguo.ios")
        app.launch()
        if app.buttons["开始发现好故事"].waitForExistence(timeout: 10) { app.buttons["开始发现好故事"].tap() }
        XCTAssertTrue(app.tabBars.buttons["我的"].waitForExistence(timeout: 10))
        app.tabBars.buttons["我的"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "下载新版本与全能签在线源")).firstMatch.tap()
        XCTAssertTrue(app.buttons["updates.check"].waitForExistence(timeout: 5))
        capture("16a-update-version")
        XCTAssertNotNil(app.debugDescription.range(of: #"\d+\.\d+\.\d+\s*[（(]\d+[）)]"#, options: .regularExpression))
        XCTAssertFalse(app.buttons["updates.export"].exists)
        app.buttons["updates.route"].tap()
        app.buttons["官方 GitHub"].tap()
        for (identifier, title) in [("github", "官方 GitHub"), ("gh-proxy", "gh-proxy"), ("ghfast", "ghfast")] {
            let copy = app.buttons["updates.copy.\(identifier)"]
            if !copy.isHittable { app.swipeUp() }
            XCTAssertTrue(copy.waitForExistence(timeout: 5)); copy.tap()
            XCTAssertTrue(app.alerts["软件源"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.alerts.staticTexts["已复制\(title)软件源地址，可在全能签中手动添加。"].exists)
            app.alerts.buttons["好"].tap()
        }
        capture("16-update-sources")
    }

    func testRealNavigationAndPlayback() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.ooiua.hongguo.ios")
        app.launch()
        if app.buttons["开始发现好故事"].waitForExistence(timeout: 10) {
            capture("01-theme-welcome"); app.buttons["开始发现好故事"].tap()
        }
        XCTAssertTrue(app.tabBars.buttons["首页"].waitForExistence(timeout: 10))
        capture("02-home")
        app.tabBars.buttons["片单"].tap()
        XCTAssertTrue(app.staticTexts["从一部好剧开始"].waitForExistence(timeout: 5))
        capture("03-library-empty")
        app.tabBars.buttons["我的"].tap(); capture("04-my")
        app.navigationBars.buttons["设置"].tap()
        app.staticTexts["主题样式"].tap(); capture("05-theme-settings")
        app.staticTexts["沉浸暗场"].tap()
        app.tabBars.buttons["首页"].tap()
        XCTAssertTrue(app.buttons["立即播放"].firstMatch.waitForExistence(timeout: 35))
        capture("06-immersive-home")
        app.tabBars.buttons["剧场"].tap()
        XCTAssertTrue(app.buttons["搜索短剧"].waitForExistence(timeout: 10))
        capture("07-discover")
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "筛选条件")).firstMatch.tap()
        capture("07b-filters"); app.buttons["查看结果"].tap()
        app.buttons["搜索短剧"].tap()
        let input = app.textFields["搜索剧名或关键词"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("王妈"); app.buttons["搜索"].firstMatch.tap()
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "查看选集")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 40))
        capture("08-search-results"); result.tap()
        XCTAssertTrue(app.navigationBars["剧集详情"].waitForExistence(timeout: 10))
        let play = app.buttons["播放第 1 集"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        capture("09-detail")
        if app.buttons["本机收藏"].exists { app.buttons["本机收藏"].tap() }
        play.tap()
        XCTAssertTrue(app.buttons["关闭播放器"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 90))
        capture("10-player-live")
        app.buttons["player.speed"].tap()
        XCTAssertTrue(app.navigationBars["播放倍速"].waitForExistence(timeout: 5))
        capture("11-speed-picker")
        app.buttons["1.5×"].tap()
        XCTAssertTrue(app.buttons["player.speed"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["player.speed"].value as? String, "1.5×")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).press(forDuration: 0.7)
        XCTAssertEqual(app.buttons["player.speed"].value as? String, "1.5×")
        app.buttons["下一集"].tap()
        let second = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "第 2 集 / 共")).firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 90))
        capture("12-player-next")
        app.buttons["player.episodes"].tap()
        XCTAssertTrue(app.buttons["3"].waitForExistence(timeout: 5))
        capture("12b-episode-picker"); app.buttons["3"].tap()
        let third = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "第 3 集 / 共")).firstMatch
        XCTAssertTrue(third.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 90))
        capture("12c-third-episode")
        app.buttons["关闭播放器"].tap()
        app.tabBars.buttons["追剧"].tap()
        let resume = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "继续观看")).firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        capture("13-library-history")
        app.tabBars.buttons["我的"].tap()
        XCTAssertTrue(app.staticTexts["内容卡片"].waitForExistence(timeout: 5))
        app.staticTexts["内容卡片"].tap(); app.tabBars.buttons["首页"].tap()
        capture("14-cards-home")
        app.terminate(); app.launch()
        XCTAssertTrue(app.tabBars.buttons["片单"].waitForExistence(timeout: 10))
        app.tabBars.buttons["片单"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "第 3 集")).firstMatch.waitForExistence(timeout: 10))
        capture("15-library-after-relaunch")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let tree = XCTAttachment(string: XCUIApplication(bundleIdentifier: "com.ooiua.hongguo.ios").debugDescription)
        tree.name = name + "-accessibility"; tree.lifetime = .keepAlways; add(tree)
    }
}
