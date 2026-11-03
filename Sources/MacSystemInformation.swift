import Foundation

/// System Profiler exposes nearly all locally readable hardware, OS and installed
/// software details without root privileges. Keep every supported data type in a
/// clearly named group, but query only on demand: applications, fonts and logs
/// can be expensive on large installations.
struct MacInfoCategory: Identifiable, Sendable {
    let id: String
    let titleKey: String
    let symbol: String
    let types: [String]
}

enum MacInfoCatalog {
    static let categories: [MacInfoCategory] = [
        .init(id: "overview", titleKey: "MACINFO_OVERVIEW", symbol: "desktopcomputer",
              types: ["SPHardwareDataType", "SPSoftwareDataType", "SPInternationalDataType"]),
        .init(id: "power", titleKey: "MACINFO_POWER", symbol: "battery.100",
              types: ["SPPowerDataType", "SPiBridgeDataType"]),
        .init(id: "displays", titleKey: "MACINFO_DISPLAYS", symbol: "display",
              types: ["SPDisplaysDataType", "SPPCIDataType"]),
        .init(id: "memory", titleKey: "MACINFO_MEMORY", symbol: "cpu",
              types: ["SPMemoryDataType", "SPAppleVirtualPlatformDataType"]),
        .init(id: "storage", titleKey: "MACINFO_STORAGE", symbol: "externaldrive",
              types: ["SPStorageDataType", "SPNVMeDataType", "SPSerialATADataType",
                      "SPParallelATADataType", "SPParallelSCSIDataType",
                      "SPSASDataType", "SPFibreChannelDataType"]),
        .init(id: "network", titleKey: "MACINFO_NETWORK", symbol: "wifi",
              types: ["SPNetworkDataType", "SPAirPortDataType", "SPEthernetDataType",
                      "SPNetworkLocationDataType", "SPNetworkVolumeDataType"]),
        .init(id: "ports", titleKey: "MACINFO_PORTS", symbol: "cable.connector",
              types: ["SPUSBHostDataType", "SPThunderboltDataType",
                      "SPCardReaderDataType", "SPSPIDataType"]),
        .init(id: "media", titleKey: "MACINFO_MEDIA", symbol: "hifispeaker",
              types: ["SPAudioDataType", "SPCameraDataType",
                      "SPRawCameraDataType", "SPBluetoothDataType"]),
        .init(id: "security", titleKey: "MACINFO_SECURITY", symbol: "lock.shield",
              types: ["SPFirewallDataType", "SPSecureElementDataType",
                      "SPSmartCardsDataType", "SPConfigurationProfileDataType",
                      "SPManagedClientDataType"]),
        .init(id: "software", titleKey: "MACINFO_SOFTWARE", symbol: "app.badge",
              types: ["SPApplicationsDataType", "SPExtensionsDataType",
                      "SPDeveloperToolsDataType", "SPInstallHistoryDataType",
                      "SPDisabledSoftwareDataType", "SPLegacySoftwareDataType",
                      "SPStartupItemDataType", "SPPrefPaneDataType"]),
        .init(id: "fonts", titleKey: "MACINFO_FONTS", symbol: "textformat",
              types: ["SPFontsDataType", "SPFrameworksDataType"]),
        .init(id: "printers", titleKey: "MACINFO_PRINTERS", symbol: "printer",
              types: ["SPPrintersDataType", "SPPrintersSoftwareDataType",
                      "SPDiscBurningDataType"]),
        .init(id: "accessibility", titleKey: "MACINFO_ACCESSIBILITY", symbol: "accessibility",
              types: ["SPUniversalAccessDataType"]),
        .init(id: "diagnostics", titleKey: "MACINFO_DIAGNOSTICS", symbol: "waveform.path.ecg",
              types: ["SPDiagnosticsDataType", "SPLogsDataType"])
    ]

    static func sourceName(_ type: String) -> String {
        let special: [String: String] = [
            "SPHardwareDataType": "Hardware", "SPSoftwareDataType": "macOS",
            "SPPowerDataType": "Battery & Power", "SPDisplaysDataType": "Displays",
            "SPAirPortDataType": "Wi-Fi", "SPUSBHostDataType": "USB",
            "SPNVMeDataType": "NVMe", "SPPCIDataType": "PCI",
            "SPiBridgeDataType": "Apple iBridge", "SPAppleVirtualPlatformDataType": "Virtual Platform",
            "SPNetworkLocationDataType": "Network Locations",
            "SPConfigurationProfileDataType": "Configuration Profiles",
            "SPManagedClientDataType": "Device Management"
        ]
        if let name = special[type] { return name }
        return type.replacingOccurrences(of: "^SP", with: "", options: .regularExpression)
            .replacingOccurrences(of: "DataType$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
    }
}

struct MacInfoItem: Identifiable, Sendable {
    let id: Int
    let name: String
    let value: String
}

struct MacInfoSource: Identifiable, Sendable {
    let id: String
    let name: String
    let items: [MacInfoItem]
}

struct MacInfoReport: Sendable {
    let sources: [MacInfoSource]
    let error: String?
    var itemCount: Int { sources.reduce(0) { $0 + $1.items.count } }
}

/// Lossless traversal of the JSON property tree for ordinary System Profiler
/// scalars. Parent paths are kept so similarly named properties in different
/// devices cannot be confused. Empty subtrees are omitted.
enum MacInfoParser {
    static func parse(_ data: Data, types: [String]) -> [MacInfoSource]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return types.compactMap { type in
            guard let payload = root[type] else { return nil }
            var rows: [MacInfoItem] = []
            visit(payload, path: [], depth: 0, rows: &rows)
            return rows.isEmpty ? nil : MacInfoSource(
                id: type, name: MacInfoCatalog.sourceName(type), items: rows
            )
        }
    }

    private static func visit(_ value: Any, path: [String], depth: Int,
                              rows: inout [MacInfoItem]) {
        guard depth < 20, rows.count < 20000 else { return }
        if let dictionary = value as? [String: Any] {
            // The _name field identifies a device, app or subsection; keep it as a value.
            for key in dictionary.keys.sorted() {
                guard let child = dictionary[key] else { continue }
                visit(child, path: path + [displayKey(key)], depth: depth + 1, rows: &rows)
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                guard rows.count < 20000 else { break }
                let name = (child as? [String: Any])?["_name"] as? String
                let segment = (name?.isEmpty == false) ? name! : "#\(index + 1)"
                visit(child, path: path + [segment], depth: depth + 1, rows: &rows)
            }
        } else if let scalar = scalarText(value), !path.isEmpty {
            rows.append(.init(id: rows.count,
                              name: path.joined(separator: " › "), value: scalar))
        }
    }

    private static func displayKey(_ key: String) -> String {
        if key == "_name" { return "Name" }
        return key.replacingOccurrences(of: "_", with: " ")
    }

    private static func scalarText(_ value: Any) -> String? {
        if value is NSNull { return nil }
        if let text = value as? String { return text }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        return String(describing: value)
    }
}
