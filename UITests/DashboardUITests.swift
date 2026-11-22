import XCTest

final class DashboardUITests: XCTestCase {
    private let responseTimeout: TimeInterval = 40

    #if DEBUG
    @MainActor func testFirstLaunchHasUsefulOnboardingAndNoMeasurements() {
        let app = launch(appearance: "light")
        XCTAssertTrue(app.staticTexts["Подключите автомобиль"].waitForExistence(timeout: responseTimeout))
        let find = app.buttons["find-adapter"]
        XCTAssertTrue(find.isHittable)
        XCTAssertEqual(find.label, "Найти адаптер")
        XCTAssertFalse(app.staticTexts["coolant-value"].exists)
        XCTAssertFalse(app.staticTexts["rpm-value"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        snapshot(app, named: "01-Onboarding")
    }

    @MainActor func testDiscoverySeparatesLikelyAdaptersAndShowsUnnamedOnRequest() {
        let app = launch(appearance: "light", options: ["--adapter-list-fixture"])
        app.buttons["find-adapter"].tap()
        XCTAssertTrue(app.staticTexts["likely-adapters"].waitForExistence(timeout: responseTimeout))
        XCTAssertTrue(app.staticTexts["other-devices"].exists)
        let named = app.buttons.matching(NSPredicate(format: "label == %@", "Vgate iCar Pro BLE"))
        XCTAssertEqual(named.count, 2)
        XCTAssertTrue(app.buttons["IOS-VLINK"].exists)
        let identifiers = (0..<named.count).compactMap { named.element(boundBy: $0).value as? String }
        XCTAssertEqual(Set(identifiers), ["ID · A481B001", "ID · A481B002"])
        XCTAssertFalse(app.buttons["Устройство без имени"].exists)
        let extended = app.buttons["extended-discovery"]
        for _ in 0..<3 where !extended.isHittable { app.swipeUp() }
        extended.tap()
        XCTAssertTrue(app.buttons["Устройство без имени"].waitForExistence(timeout: responseTimeout))
        snapshot(app, named: "02-Adapter-Discovery")
        app.buttons["close-adapter-setup"].tap()
        XCTAssertTrue(app.buttons["find-adapter"].waitForExistence(timeout: responseTimeout))
    }

    @MainActor func testWaitingForFirstReadingDoesNotShowEmptyInstruments() {
        let app = launch(appearance: "dark", options: ["--adapter-waiting-fixture"])
        XCTAssertTrue(app.staticTexts["Ожидание первого замера"].waitForExistence(timeout: responseTimeout))
        XCTAssertFalse(app.staticTexts["coolant-value"].exists)
        XCTAssertFalse(app.buttons["retry-connection"].exists)
        snapshot(app, named: "03-Connecting")
    }

    @MainActor func testDarkDashboardFitsBeforeScrolling() {
        let app = launch(scenario: "warmup")
        let temperature = app.staticTexts["coolant-value"]
        let rpm = app.staticTexts["rpm-value"]
        let voltage = app.staticTexts["voltage-value"]
        XCTAssertTrue(temperature.waitForLabel(matching: "[0-9]+ градусов Цельсия", timeout: responseTimeout))
        XCTAssertTrue(rpm.waitForLabel(matching: ".+ оборотов в минуту", timeout: responseTimeout))
        XCTAssertTrue(voltage.waitForLabel(matching: ".+ вольт", timeout: responseTimeout))
        XCTAssertTrue(app.staticTexts["source-indicator"].exists)
        let chart = app.descendants(matching: .any)["warmup-plot"].firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: responseTimeout))
        XCTAssertGreaterThan(chart.frame.height, 0)
        XCTAssertLessThanOrEqual(chart.frame.maxY, app.frame.maxY - 25)
        XCTAssertLessThan(temperature.frame.minY, rpm.frame.minY)
        XCTAssertLessThan(rpm.frame.minY, chart.frame.minY)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        snapshot(app, named: "04-Driving-Dark")
    }

    @MainActor func testLightDashboardAndNavigation() {
        let app = launch(scenario: "warmup", appearance: "light")
        XCTAssertTrue(app.staticTexts["voltage-value"].waitForLabel(matching: ".+ вольт", timeout: responseTimeout))
        let chart = app.descendants(matching: .any)["warmup-plot"].firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: responseTimeout))
        XCTAssertLessThanOrEqual(chart.frame.maxY, app.frame.maxY - 25)
        snapshot(app, named: "05-Driving-Light")

        app.buttons["history-nav"].tap()
        XCTAssertTrue(app.staticTexts["Температура за сеанс"].waitForExistence(timeout: responseTimeout))
        snapshot(app, named: "06-Trip-History")
        app.navigationBars.buttons.firstMatch.tap()

        app.buttons["settings-nav"].tap()
        XCTAssertTrue(app.staticTexts["Оформление"].waitForExistence(timeout: responseTimeout))
        XCTAssertFalse(app.descendants(matching: .any)["simulation-scenario"].firstMatch.exists)
        snapshot(app, named: "07-Settings")
        let diagnostics = app.buttons["diagnostics-nav"]
        for _ in 0..<5 where !diagnostics.isHittable { app.swipeUp() }
        #if CARGAUGE_BASIC
        XCTAssertFalse(app.switches["auto-live-activity"].exists)
        #else
        XCTAssertTrue(app.switches["auto-live-activity"].exists)
        #endif
        diagnostics.tap()
        let pid = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "PID 0105")).firstMatch
        XCTAssertTrue(pid.waitForExistence(timeout: responseTimeout))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "0100")).firstMatch.exists)
        snapshot(app, named: "08-Diagnostics")
    }

    @MainActor func testThresholdCanBeAdjustedAndReset() {
        let app = launch()
        app.buttons["settings-nav"].tap()
        let reset = app.buttons["reset-thresholds"]
        for _ in 0..<4 where !reset.isHittable { app.swipeUp() }
        if reset.isEnabled { reset.tap() }
        let stepper = app.steppers["warning-threshold"]
        XCTAssertTrue(stepper.waitForTemperature(105, timeout: responseTimeout))
        if !stepper.isHittable { app.swipeDown() }
        stepper.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(stepper.waitForTemperature(106, timeout: responseTimeout))
        for _ in 0..<3 where !reset.isHittable { app.swipeUp() }
        reset.tap()
        XCTAssertTrue(stepper.waitForTemperature(105, timeout: responseTimeout))
    }

    @MainActor func testOverheatIsVisibleAndExplained() {
        let app = launch(scenario: "overheat")
        let warning = app.descendants(matching: .any)["overheat-critical"].firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: responseTimeout))
        snapshot(app, named: "09-Overheat")
    }

    @MainActor func testDisconnectClearsTemperatureAndOffersRetry() {
        let app = launch(scenario: "disconnect")
        let temperature = app.staticTexts["coolant-value"]
        XCTAssertTrue(temperature.waitForExistence(timeout: responseTimeout))
        XCTAssertTrue(temperature.wait(for: \.label, toEqual: "Нет свежих данных", timeout: responseTimeout))
        let retry = app.buttons["retry-connection"]
        XCTAssertTrue(retry.waitForExistence(timeout: responseTimeout))
        snapshot(app, named: "10-Lost-Connection")
    }

    @MainActor func testReconnectReplacesMissingTemperatureWithFreshSample() {
        let app = launch(scenario: "reconnect")
        let value = app.staticTexts["coolant-value"]
        XCTAssertTrue(value.waitForLabel(matching: "[0-9]+ градусов Цельсия", timeout: responseTimeout))
        XCTAssertTrue(value.wait(for: \.label, toEqual: "Нет свежих данных", timeout: responseTimeout))
        XCTAssertTrue(value.waitForLabel(matching: "[0-9]+ градусов Цельсия", timeout: responseTimeout))
        snapshot(app, named: "13-Recovered")
    }

    #if !CARGAUGE_BASIC
    @MainActor func testGlanceSurfacesExpireAndActivityWorksWithoutGroup() {
        let app = launch(options: ["--glance-preview-fixture"])
        func surface(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
        func expect(_ label: String, in element: XCUIElement) {
            XCTAssertTrue(element.waitForLabel(matching: "(?s).*" + label + ".*", timeout: responseTimeout))
        }

        let widget = surface("glance-widget")
        let activity = surface("glance-small-activity")
        let lock = surface("glance-lock-activity")
        for item in [widget, activity, lock] { expect("92", in: item) }
        snapshot(app, named: "14-Glance-Fresh")

        app.buttons["glance-fixture-stale"].tap()
        for item in [widget, activity, lock] {
            expect("Нет свежих данных", in: item)
            XCTAssertFalse(item.label.contains("92"))
        }
        snapshot(app, named: "15-Glance-Stale")

        app.buttons["glance-fixture-no-group"].tap()
        expect("Данные недоступны", in: widget)
        expect("92", in: activity)
        expect("92", in: lock)
        snapshot(app, named: "16-Glance-No-Group")
    }
    #endif

    @MainActor func testZeroRPMLeadsToParkedState() {
        let app = launch(scenario: "engineOff")
        guard app.staticTexts["Двигатель не работает"].waitForExistence(timeout: responseTimeout) else {
            XCTFail("The engine-off scenario did not reach its parked state.")
            return
        }
        XCTAssertTrue(app.buttons["resume-measurements"].exists)
        XCTAssertFalse(app.staticTexts["coolant-value"].exists)
        snapshot(app, named: "11-Parked")
    }

    @MainActor func testAccessibilityTextKeepsValuesReachable() {
        let app = launch(scenario: "warmup", options: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXL",
        ])
        let temperature = app.staticTexts["coolant-value"]
        XCTAssertTrue(temperature.waitForLabel(matching: "[0-9]+ градусов Цельсия", timeout: responseTimeout))
        snapshot(app, named: "12-Dynamic-Type")
        let voltage = app.staticTexts["voltage-value"]
        for _ in 0..<4 where !voltage.isHittable { app.swipeUp() }
        XCTAssertTrue(voltage.isHittable)
    }

    @MainActor func testLegacyUUIDAllowsManualConnectionWithoutDemo() {
        let app = launch(options: ["-selectedBLEPeripheral", "00000000-0000-0000-0000-000000000001",
                                   "-autoConnect", "NO"])
        XCTAssertTrue(app.buttons["retry-connection"].waitForExistence(timeout: responseTimeout))
        XCTAssertFalse(app.staticTexts["coolant-value"].exists)
        XCTAssertFalse(app.staticTexts["source-indicator"].exists)
    }

    @MainActor private func launch(scenario: String? = nil, appearance: String = "dark",
                                   options: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-appearance", appearance] + options
        if let scenario { app.launchArguments += ["--simulation-scenario", scenario] }
        app.launch()
        return app
    }
    #else
    @MainActor func testReleaseIgnoresTestLaunchFlags() {
        let app = XCUIApplication()
        app.launchArguments = ["--simulation-scenario", "overheat", "--adapter-list-fixture", "--adapter-waiting-fixture", "--glance-preview-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["find-adapter"].waitForExistence(timeout: responseTimeout))
        XCTAssertFalse(app.staticTexts["coolant-value"].exists)
        XCTAssertFalse(app.staticTexts["rpm-value"].exists)
        XCTAssertFalse(app.staticTexts["source-indicator"].exists)
        snapshot(app, named: "Release-Cold-Launch")
    }

    @MainActor func testReleaseUpgradeRetainsPreferences() {
        let app = XCUIApplication()
        app.launchArguments = ["--simulation-scenario", "overheat", "--adapter-list-fixture", "--adapter-waiting-fixture", "--glance-preview-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["retry-connection"].waitForExistence(timeout: responseTimeout))
        XCTAssertFalse(app.staticTexts["coolant-value"].exists)
        app.buttons["settings-nav"].tap()
        XCTAssertTrue(app.staticTexts["Vgate iCar Pro BLE (CI)"].waitForExistence(timeout: responseTimeout))
        let automatic = app.switches["auto-connect"]
        XCTAssertTrue(automatic.waitForExistence(timeout: responseTimeout))
        XCTAssertEqual(automatic.value as? String, "0")
        let stepper = app.steppers["warning-threshold"]
        for _ in 0..<4 where !stepper.isHittable { app.swipeUp() }
        XCTAssertTrue(stepper.waitForTemperature(108, timeout: responseTimeout))
        #if !CARGAUGE_BASIC
        let activity = app.switches["auto-live-activity"]
        for _ in 0..<5 where !activity.isHittable { app.swipeUp() }
        XCTAssertEqual(activity.value as? String, "1")
        #endif
        snapshot(app, named: "Release-Upgrade")
    }
    #endif

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
        return wait(for: NSPredicate(format: "exists == YES AND (value == %@ OR label CONTAINS %@)", temperature, temperature), timeout: timeout)
    }

    @MainActor func waitForLabel(matching pattern: String, timeout: TimeInterval) -> Bool {
        return wait(for: NSPredicate(format: "exists == YES AND label MATCHES %@", pattern), timeout: timeout)
    }

    @MainActor private func wait(for predicate: NSPredicate, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
