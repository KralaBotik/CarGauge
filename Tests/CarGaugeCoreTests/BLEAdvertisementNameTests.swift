import XCTest
@testable import CarGaugeCore

final class BLEAdvertisementNameTests: XCTestCase {
    func testCurrentAdvertisementOverridesCachedPeripheralName() {
        XCTAssertEqual(BLEAdvertisementName.preferred(advertised: "  Vgate\tiCar Pro  ",
                                                       peripheral: "Old name", previousAdvertisement: "OBD II"),
                       "Vgate iCar Pro")
    }

    func testLaterNamelessPacketPreservesAdvertisement() {
        XCTAssertEqual(BLEAdvertisementName.preferred(advertised: "  ", peripheral: "Old name",
                                                       previousAdvertisement: "iCar Pro"), "iCar Pro")
    }

    func testPeripheralFallbackAndUnnamedDevice() {
        XCTAssertEqual(BLEAdvertisementName.preferred(advertised: nil, peripheral: "  OBDⅡ ",
                                                       previousAdvertisement: nil), "OBDⅡ")
        XCTAssertEqual(BLEAdvertisementName.preferred(advertised: nil, peripheral: "\u{0000}  ",
                                                       previousAdvertisement: nil), "")
    }

    func testClassificationKeepsNonAdapterNamesSeparate() {
        for name in ["Vgate iCar Pro BLE", "iCar", "iCarPro", "OBD-II", "OBD2", "ELM327"] {
            XCTAssertTrue(BLEAdvertisementName.isLikelyOBD(name), name)
        }
        for name in ["ICARUS", "Scobd", "My headphones", ""] {
            XCTAssertFalse(BLEAdvertisementName.isLikelyOBD(name), name)
        }
        XCTAssertEqual(BLEAdvertisementName.clean("Мой\u{202E} адаптер"), "Мой адаптер")
    }
}
