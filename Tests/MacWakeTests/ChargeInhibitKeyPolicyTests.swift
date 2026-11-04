import XCTest
import MacWakeShared

final class ChargeInhibitKeyPolicyTests: XCTestCase {
    private let ui8 = ChargeInhibitKeyPolicy.fourCC("ui8 ")

    func testAlDenteLegacyCH0BRequiresKnownReadableWritableOneByteKey() {
        XCTAssertTrue(ChargeInhibitKeyPolicy.acceptsLegacyCH0B(
            dataSize: 1, dataType: ui8, attributes: 0xC0, value: 0x00
        ))
        XCTAssertTrue(ChargeInhibitKeyPolicy.acceptsLegacyCH0B(
            dataSize: 1, dataType: ui8, attributes: 0xC0, value: 0x02
        ))
    }

    func testNeverEnableCH0BIfProbeIsDeniedOrMalformed() {
        for attrs in [UInt8(0x00), 0x40, 0x80] {
            XCTAssertFalse(ChargeInhibitKeyPolicy.acceptsLegacyCH0B(
                dataSize: 1, dataType: ui8, attributes: attrs, value: 0x00
            ))
        }
        XCTAssertFalse(ChargeInhibitKeyPolicy.acceptsLegacyCH0B(
            dataSize: 1, dataType: ui8, attributes: 0xC0, value: nil
        ))
        XCTAssertFalse(ChargeInhibitKeyPolicy.acceptsLegacyCH0B(
            dataSize: 4, dataType: ui8, attributes: 0xC0, value: 0x00
        ))
        XCTAssertFalse(ChargeInhibitKeyPolicy.acceptsLegacyCH0B(
            dataSize: 1, dataType: ChargeInhibitKeyPolicy.fourCC("flt "),
            attributes: 0xC0, value: 0x00
        ))
        XCTAssertFalse(ChargeInhibitKeyPolicy.acceptsLegacyCH0B(
            dataSize: 1, dataType: ui8, attributes: 0xC0, value: 0x08
        ))
    }

    func testLegacyAlDenteUsesTwoAsInhibitValue() {
        XCTAssertEqual(ChargeInhibitKeyPolicy.legacyKey, "CH0B")
        XCTAssertEqual(ChargeInhibitKeyPolicy.legacyInhibitValue, 0x02)
        XCTAssertEqual(ChargeInhibitKeyPolicy.allowChargingValue, 0x00)
    }
}
