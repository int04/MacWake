import XCTest
@testable import MacWake

final class MacSystemInformationTests: XCTestCase {
    func testAllSystemProfilerDataTypesAreUniqueAndGrouped() {
        let categories = MacInfoCatalog.categories
        XCTAssertEqual(Set(categories.map(\.id)).count, categories.count)
        let allTypes = categories.flatMap(\.types)
        XCTAssertEqual(allTypes.count, 50)
        XCTAssertEqual(Set(allTypes).count, allTypes.count)
    }

    func testParserPreservesNestedDeviceNamesAndValues() {
        let sample = """
        {
          "SPHardwareDataType": [
            {
              "_name": "hardware_overview",
              "chip_type": "Apple M1 Pro",
              "physical_memory": "32 GB",
              "devices": [
                {"_name": "Internal", "connected": true, "size": 1024},
                {"_name": "External", "connected": false}
              ]
            }
          ],
          "SPPowerDataType": [{"_name": "power", "capacity": 90}]
        }
        """.data(using: .utf8)!
        let result = MacInfoParser.parse(
            sample, types: ["SPHardwareDataType", "SPPowerDataType", "SPNVMeDataType"]
        )
        XCTAssertEqual(result?.count, 2)
        let hardware = result?.first(where: { $0.id == "SPHardwareDataType" })
        XCTAssertTrue(hardware?.items.contains(where: {
            $0.name.contains("chip type") && $0.value == "Apple M1 Pro"
        }) == true)
        XCTAssertTrue(hardware?.items.contains(where: {
            $0.name.contains("Internal") && $0.name.contains("connected") &&
            $0.value == "true"
        }) == true)
        XCTAssertTrue(hardware?.items.contains(where: {
            $0.name.contains("External") && $0.value == "false"
        }) == true)
        XCTAssertTrue(hardware?.items.contains(where: {
            $0.name.contains("size") && $0.value == "1024"
        }) == true)
    }

    func testInvalidJSONFailsSafely() {
        XCTAssertNil(MacInfoParser.parse(Data("not-json".utf8), types: ["SPHardwareDataType"]))
    }

    func testEmptyCategoryReturnsNoSources() {
        let sample = Data(#"{"SPStorageDataType":[]}"#.utf8)
        let result = MacInfoParser.parse(sample, types: ["SPStorageDataType"])
        XCTAssertEqual(result?.count, 0)
    }
}
