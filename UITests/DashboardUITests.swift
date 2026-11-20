import XCTest

final class DashboardUITests: XCTestCase {
    @MainActor func testSimulatorShowsMeasurementsAndClearsOnStop() {
        let app = launch("warmup")
        let temperature = app.staticTexts["coolant-value"]
        let rpm = app.staticTexts["rpm-value"]
        let voltage = app.staticTexts["voltage-value"]
        XCTAssertTrue(temperature.waitForExistence(timeout: 10))
        XCTAssertTrue(temperature.waitForLabel(matching: "[0-9]+ °C", timeout: 10))
        XCTAssertTrue(rpm.waitForLabel(matching: "[0-9]+", timeout: 10))
        XCTAssertTrue(voltage.waitForLabel(matching: ".+ В", timeout: 10))

        let stop = app.buttons["stop-measurement"]
        for _ in 0..<4 where !stop.isHittable { app.swipeUp() }
        XCTAssertTrue(stop.isHittable)
        stop.tap()
        XCTAssertTrue(temperature.wait(for: \.label, toEqual: "—", timeout: 5))
    }

    @MainActor func testSimulatorSurfacesOverheat() {
        let app = launch("overheat")
        XCTAssertTrue(app.staticTexts["overheat-critical"].waitForExistence(timeout: 20))
    }

    @MainActor func testSimulatorDisconnectClearsTemperature() {
        let app = launch("disconnect")
        let temperature = app.staticTexts["coolant-value"]
        XCTAssertTrue(temperature.waitForLabel(matching: "[0-9]+ °C", timeout: 10))
        XCTAssertTrue(temperature.wait(for: \.label, toEqual: "—", timeout: 15))
    }

    @MainActor private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--simulation-scenario", scenario]
        app.launch()
        return app
    }
}

private extension XCUIElement {
    @MainActor func waitForLabel(matching pattern: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == YES AND label MATCHES %@", pattern)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
