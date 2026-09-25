import XCTest

/// Settings > About this build (YUI-92, Chris on build 96: "I would like to have all
/// of the versioning information so I can know what version I'm looking at"). At the
/// bottom of Settings, under Account: version (build), channel, commit and build date
/// when the build was stamped, channel guide. One tap copies it all.
/// Demo account, no network. Screenshots go to `YUI_SHOTS` when set.
final class AboutBuildTests: XCTestCase {
    func testLight() throws { try run(appearance: "light") }

    func testDark() throws { try run(appearance: "dark") }

    private func run(appearance: String) throws {
        let app = XCUIApplication()
        let shots = ProcessInfo.processInfo.environment["YUI_SHOTS"].map { URL(fileURLWithPath: $0) }
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            if let shots { try? png.write(to: shots.appending(path: "\(name)-\(appearance).png")) }
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = "\(name)-\(appearance)"
            a.lifetime = .keepAlways
            add(a)
        }

        app.launchArguments = ["-yuiDemoAccount", "-yuiDemo", "-yuiSettings", "-yuiSettingsLarge", "-appearance", appearance]
        app.launch()

        let about = app.buttons["aboutBuild"]
        XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 15), "Settings did not open")
        for _ in 0..<6 where !about.isHittable { app.swipeUp() }
        XCTAssertTrue(about.isHittable, "About this build is not on screen")

        let version = Bundle(for: Self.self).infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        XCTAssertTrue(about.label.contains("About this build"), about.label)
        XCTAssertTrue(about.label.contains("Yui \(version) ("), about.label)
        XCTAssertTrue(about.label.contains("Channel guide v") || about.label.contains("Local build"), about.label)
        shot("about-build")

        about.tap()
        XCTAssertTrue(app.staticTexts["Copied"].waitForExistence(timeout: 3) || about.label.contains("Copied"),
                      "no Copied confirmation")
        shot("about-build-copied")
    }
}
