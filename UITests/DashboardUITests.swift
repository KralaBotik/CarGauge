import XCTest

final class DashboardUITests: XCTestCase {
    // A busy hosted simulator can spend several seconds servicing each accessibility query.
    private let simulatorResponseTimeout: TimeInterval = 40

    @MainActor func testDarkDashboardFitsBeforeScrollingAndClearsOnStop() {
        let app = launch("warmup", appearance: "dark")
        let temperature = app.staticTexts["coolant-value"]
        let rpm = app.staticTexts["rpm-value"]
        let voltage = app.staticTexts["voltage-value"]
        XCTAssertTrue(temperature.waitForLabel(matching: "[0-9]+ °C", timeout: simulatorResponseTimeout))
        XCTAssertTrue(rpm.waitForLabel(matching: "[0-9]+", timeout: simulatorResponseTimeout))
        XCTAssertTrue(voltage.waitForLabel(matching: ".+ В", timeout: simulatorResponseTimeout))
        XCTAssertTrue(app.buttons["source-simulator"].isSelected)

        let chart = app.descendants(matching: .any)["warmup-plot"].firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 5))
        XCTAssertFalse(chart.frame.isEmpty)
        XCTAssertLessThanOrEqual(chart.frame.maxY, app.tabBars.firstMatch.frame.minY + 1)
        XCTAssertLessThan(temperature.frame.minY, rpm.frame.minY)
        XCTAssertLessThan(rpm.frame.minY, chart.frame.minY)
        XCTAssertFalse(app.descendants(matching: .any)["coolant-pid"].firstMatch.exists)
        snapshot(app, named: "Dashboard-Dark")

        let stop = app.buttons["stop-measurement"]
        XCTAssertTrue(stop.isHittable)
        stop.tap()
        XCTAssertTrue(temperature.wait(for: \.label, toEqual: "—", timeout: 5))
        app.tabBars.buttons["История"].tap()
        let lastReading = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Последний замер,")).firstMatch
        XCTAssertTrue(lastReading.waitForExistence(timeout: 5))
    }

    @MainActor func testLightDashboardAndTabs() {
        let app = launch("warmup", appearance: "light")
        XCTAssertTrue(app.staticTexts["voltage-value"].waitForLabel(matching: ".+ В", timeout: simulatorResponseTimeout))
        snapshot(app, named: "Dashboard-Light")

        app.tabBars.buttons["История"].tap()
        XCTAssertTrue(app.staticTexts["Температура за сеанс"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Диагностика"].tap()
        let coolantPID = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "PID 0105")).firstMatch
        XCTAssertTrue(coolantPID.waitForExistence(timeout: 5))
        app.tabBars.buttons["Настройки"].tap()
        XCTAssertTrue(app.staticTexts["Температурные пороги"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Оформление"].exists)
        let liveActivityButton = app.buttons["live-activity-button"]
        let automaticActivity = app.switches["auto-live-activity"]
        #if CARGAUGE_BASIC
        XCTAssertFalse(liveActivityButton.exists)
        XCTAssertFalse(automaticActivity.exists)
        #else
        for _ in 0..<4 where !liveActivityButton.isHittable { app.swipeUp() }
        XCTAssertTrue(liveActivityButton.isHittable)
        XCTAssertTrue(automaticActivity.exists)
        #endif
    }

    @MainActor func testThresholdCanBeAdjustedAndReset() {
        let app = launch("warmup", appearance: "dark")
        let stop = app.buttons["stop-measurement"]
        XCTAssertTrue(stop.waitForExistence(timeout: simulatorResponseTimeout))
        stop.tap()
        app.tabBars.buttons["Настройки"].tap()
        let reset = app.buttons["reset-thresholds"]
        XCTAssertTrue(reset.waitForExistence(timeout: simulatorResponseTimeout))
        if reset.isEnabled { reset.tap() }
        let stepper = app.steppers["warning-threshold"]
        XCTAssertTrue(stepper.waitForTemperature(105, timeout: simulatorResponseTimeout))
        stepper.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(stepper.waitForTemperature(106, timeout: simulatorResponseTimeout))
        reset.tap()
        XCTAssertTrue(stepper.waitForTemperature(105, timeout: simulatorResponseTimeout))
    }

    @MainActor func testSimulatorSurfacesOverheat() {
        let app = launch("overheat", appearance: "dark")
        let warning = app.descendants(matching: .any)["overheat-critical"].firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: simulatorResponseTimeout))
        snapshot(app, named: "Dashboard-Overheat")
    }

    @MainActor func testSimulatorDisconnectClearsTemperature() {
        let app = launch("disconnect", appearance: "dark")
        let temperature = app.staticTexts["coolant-value"]
        XCTAssertTrue(temperature.waitForLabel(matching: "[0-9]+ °C", timeout: simulatorResponseTimeout))
        XCTAssertTrue(temperature.wait(for: \.label, toEqual: "—", timeout: 15))
    }

    @MainActor func testAccessibilityTextKeepsValuesReachable() {
        let app = launch("warmup", appearance: "dark", accessibilityText: true)
        let temperature = app.staticTexts["coolant-value"]
        XCTAssertTrue(temperature.waitForLabel(matching: "[0-9]+ °C", timeout: simulatorResponseTimeout))
        snapshot(app, named: "Dashboard-Accessibility")
        let voltage = app.staticTexts["voltage-value"]
        for _ in 0..<4 where !voltage.isHittable { app.swipeUp() }
        XCTAssertTrue(voltage.isHittable)
    }

    @MainActor func testRememberedAdapterUsesVehicleWithAutoConnectDisabled() {
        let app = XCUIApplication()
        app.launchArguments = ["-selectedBLEPeripheral", "00000000-0000-0000-0000-000000000001",
                               "-autoConnect", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["source-vehicle"].waitForExistence(timeout: simulatorResponseTimeout))
        XCTAssertTrue(app.buttons["source-vehicle"].isSelected)
        XCTAssertTrue(app.buttons["start-measurement"].exists)
        XCTAssertEqual(app.staticTexts["coolant-value"].label, "—")
    }

    @MainActor func testManualStopSurvivesReturnFromBackground() {
        let app = launch("warmup", appearance: "dark")
        XCTAssertTrue(app.staticTexts["coolant-value"].waitForLabel(matching: "[0-9]+ °C", timeout: simulatorResponseTimeout))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["stop-measurement"].waitForExistence(timeout: simulatorResponseTimeout))
        app.buttons["stop-measurement"].tap()
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["start-measurement"].waitForExistence(timeout: simulatorResponseTimeout))
        XCTAssertEqual(app.staticTexts["coolant-value"].label, "—")
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
    @MainActor func waitForTemperature(_ degrees: Int, timeout: TimeInterval) -> Bool {
        let temperature = "\(degrees) °C"
        let predicate = NSPredicate(format: "exists == YES AND (value == %@ OR label CONTAINS %@)", temperature, temperature)
        return wait(for: predicate, timeout: timeout)
    }

    @MainActor func waitForLabel(matching pattern: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == YES AND label MATCHES %@", pattern)
        return wait(for: predicate, timeout: timeout)
    }

    @MainActor private func wait(for predicate: NSPredicate, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
