import Foundation

/// Eligibility rules for the legacy CH0B charge-inhibit mechanism used by early
/// AlDente releases. A key name alone must never authorize an SMC write.
public enum ChargeInhibitKeyPolicy {
    public static let legacyKey = "CH0B"
    public static let legacyInhibitValue: UInt8 = 0x02
    public static let allowChargingValue: UInt8 = 0x00

    /// Attribute bits 0x80 / 0x40 represent readable / writable in AppleSMC.
    /// CH0B must be one byte of type "ui8 " and in a known state before use.
    public static func acceptsLegacyCH0B(
        dataSize: UInt32, dataType: UInt32,
        attributes: UInt8, value: UInt8?
    ) -> Bool {
        guard dataSize == 1,
              dataType == fourCC("ui8 "),
              (attributes & 0xC0) == 0xC0,
              let value else { return false }
        return value == allowChargingValue || value == legacyInhibitValue
    }

    public static func fourCC(_ value: String) -> UInt32 {
        value.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
