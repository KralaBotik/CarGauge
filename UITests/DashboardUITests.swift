import XCTest

final class DashboardUITests: XCTestCase {
    @MainActor func testDarkDashboardFitsBeforeScrollingAndClearsOnStop() {
        let app = launch("warmup", appearance: "dark")
        let temperature = app.staticTexts["coolant-value"]
        let rpm = app.staticTexts["rpm-value"]
        let voltage = app.staticTexts["voltage-value"]
        XCTAssertTrue(temperature.waitForLabel(matching: "[0-9]+ °C", timeout: 10))
        XCTAssertTrue(rpm.waitForLabel(matching: "[0-9]+", timeout: 10))
        XCTAssertTrue(voltage.waitForLabel(matching: ".+ В", timeout: 10))
        XCTAssertTrue(app.buttons["source-simulator"].isSelected)

        let chart = app.descendants(matching: .any)["warmup-plot"].firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 5))
        XCTAssertFalse(chart.frame.isEmpty)
        XCTAssertLessThanOrEqual(chart.frame.maxY, app.tabBars.firstMatch.frame.minY + 1)
        XCTAssertLessThan(temperature.frame.minY, rpm.frame.minY)
        XCTAssertLessThan(rpm.frame.minY, chart.frame.minY)
        XCTAssertFalse(app.staticTexts["PID 0105"].exists)
        snapshot(app, named: "Dashboard-Dark")

        let stop = app.buttons["stop-measurement"]
        XCTAssertTrue(stop.isHittable)
        stop.tap()
        XCTAssertTrue(temperature.wait(for: \.label, toEqual: "—", timeout: 5))
        app.tabBars.buttons["История"].tap()
        XCTAssertTrue(app.staticTexts["Последний замер"].waitForExistence(timeout: 5))
    }

    @MainActor func testLightDashboardAndTabs() {
        let app = launch("warmup", appearance: "light")
        XCTAssertTrue(app.staticTexts["voltage-value"].waitForLabel(matching: ".+ В", timeout: 10))
        snapshot(app, named: "Dashboard-Light")

        app.tabBars.buttons["История"].tap()
        XCTAssertTrue(app.staticTexts["Температура за сеанс"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Диагностика"].tap()
        XCTAssertTrue(app.staticTexts["PID 0105"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Настройки"].tap()
        XCTAssertTrue(app.staticTexts["Температурные пороги"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Оформление"].exists)
        let liveActivityButton = app.buttons["live-activity-button"]
        #if CARGAUGE_BASIC
        XCTAssertFalse(liveActivityButton.exists)
        #else
        for _ in 0..<4 where !liveActivityButton.isHittable { app.swipeUp() }
        XCTAssertTrue(liveActivityButton.isHittable)
        #endif
    }

    @MainActor func testThresholdCanBeAdjustedAndReset() {
        let app = launch("warmup", appearance: "dark")
        app.tabBars.buttons["Настройки"].tap()
        let reset = app.buttons["reset-thresholds"]
        if reset.isEnabled { reset.tap() }
        let stepper = app.steppers["warning-threshold"]
        XCTAssertTrue(stepper.waitForExistence(timeout: 5))
        stepper.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(app.staticTexts["106 °C"].exists)
        reset.tap()
        XCTAssertTrue(app.staticTexts["105 °C"].exists)
    }

    @MainActor func testSimulatorSurfacesOverheat() {
        let app = launch("overheat", appearance: "dark")
        let warning = app.descendants(matching: .any)["overheat-critical"].firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 25))
        snapshot(app, named: "Dashboard-Overheat")
    }

    @MainActor func testSimulatorDisconnectClearsTemperature() {
        let app = launch("disconnect", appearance: "dark")
        let temperature = app.staticTexts["coolant-value"]
        XCTAssertTrue(temperature.waitForLabel(matching: "[0-9]+ °C", timeout: 10))
        XCTAssertTrue(temperature.wait(for: \.label, toEqual: "—", timeout: 15))
    }

    @MainActor func testAccessibilityTextKeepsValuesReachable() {
        let app = launch("warmup", appearance: "dark", accessibilityText: true)
        let temperature = app.staticTexts["coolant-value"]
        XCTAssertTrue(temperature.waitForLabel(matching: "[0-9]+ °C", timeout: 10))
        snapshot(app, named: "Dashboard-Accessibility")
        let voltage = app.staticTexts["voltage-value"]
        for _ in 0..<4 where !voltage.isHittable { app.swipeUp() }
        XCTAssertTrue(voltage.isHittable)
    }

    @MainActor private func launch(_ scenario: String, appearance: String, accessibilityText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--simulation-scenario", scenario, "-appearance", appearance]
        if accessibilityText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXL"]
        }
        app.launch()
        return app
    }

    @MainActor private func snapshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private extension XCUIElement {
    @MainActor func waitForLabel(matching pattern: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == YES AND label MATCHES %@", pattern)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
