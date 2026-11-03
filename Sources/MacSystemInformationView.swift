#if !APPSTORE
import AppKit
import Foundation
import SwiftUI

/// Everything here is collected locally. No diagnostics are uploaded or written to disk.
private enum MacInfoReader {
    static func read(_ category: MacInfoCategory) -> MacInfoReport {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-json", "-detailLevel", "full"] + category.types
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return MacInfoReport(sources: [], error: error.localizedDescription)
        }

        // Heavy sources (installed applications, fonts and frameworks) are loaded
        // only on request. Bound the runtime so a broken subsystem cannot hang
        // the More tab. Pipe output is drained while the process is running.
        let timeout: TimeInterval = ["software", "fonts", "diagnostics"].contains(category.id) ? 90 : 40
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout, execute: watchdog
        )
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0 else {
            return MacInfoReport(sources: [], error: "MACINFO_LOAD_FAILED")
        }
        guard let sources = MacInfoParser.parse(data, types: category.types) else {
            return MacInfoReport(sources: [], error: "MACINFO_PARSE_FAILED")
        }
        return MacInfoReport(sources: sources, error: nil)
    }
}

@MainActor
private final class MacInfoModel: ObservableObject {
    @Published private(set) var reports: [String: MacInfoReport] = [:]
    @Published private(set) var loading: Set<String> = []
    @Published private(set) var loadingAll = false
    @Published private(set) var lastUpdated: Date?

    func load(_ category: MacInfoCategory, force: Bool = false) async {
        guard !loading.contains(category.id),
              force || reports[category.id] == nil else { return }
        loading.insert(category.id)

        let report = await Task.detached(priority: .utility) {
            MacInfoReader.read(category)
        }.value

        reports[category.id] = report
        loading.remove(category.id)
        lastUpdated = Date()
    }

    func loadAll() {
        guard !loadingAll else { return }
        loadingAll = true
        Task {
            for category in MacInfoCatalog.categories {
                await load(category)
            }
            loadingAll = false
        }
    }

    func refreshLoaded() {
        guard !loadingAll else { return }
        Task {
            let selected = MacInfoCatalog.categories.filter { reports[$0.id] != nil }
            for category in selected.isEmpty ? Array(MacInfoCatalog.categories.prefix(2)) : selected {
                await load(category, force: true)
            }
        }
    }

    func copyLoadedToPasteboard() {
        let lines = MacInfoCatalog.categories.compactMap { category -> String? in
            guard let report = reports[category.id] else { return nil }
            let sources = report.sources.map { source in
                (["## " + source.name] +
                 source.items.map { $0.name + ": " + $0.value }).joined(separator: "\n")
            }
            return (["# " + category.titleKey] + sources).joined(separator: "\n")
        }
        let report = lines.joined(separator: "\n\n")
        guard !report.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }
}

/// System Profiler mirrors macOS "System Information" and is not a live telemetry
/// sampler. Categories load on expansion; only Hardware/OS and Battery/Power
/// prefetch on opening More. Explicit "Load all" scans expensive categories.
struct MacSystemInformationView: View {
    @StateObject private var model = MacInfoModel()
    @State private var expandedGroups: Set<String> = ["overview", "power"]
    @State private var expandedSources: Set<String> = [
        "SPHardwareDataType", "SPSoftwareDataType", "SPPowerDataType"
    ]
    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("MACINFO_SUBTITLE")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("MACINFO_SEARCH", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))

                HStack(spacing: 6) {
                    Button {
                        model.loadAll()
                    } label: {
                        Label("MACINFO_LOAD_ALL", systemImage: "square.stack.3d.up")
                    }
                    .disabled(model.loadingAll)
                    Button {
                        model.refreshLoaded()
                    } label: {
                        Label("MACINFO_REFRESH", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.loadingAll || !model.loading.isEmpty)
                    Button {
                        model.copyLoadedToPasteboard()
                    } label: {
                        Label("MACINFO_COPY", systemImage: "doc.on.doc")
                    }
                    .disabled(model.reports.isEmpty)
                }
                .font(.system(size: 10))
                .buttonStyle(.bordered)
                .controlSize(.small)

                if model.loadingAll {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("MACINFO_LOADING_ALL")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }
                if let updated = model.lastUpdated {
                    Text(String(format: String(localized: "MACINFO_UPDATED"),
                                DateFormatter.localizedString(
                                    from: updated, dateStyle: .short, timeStyle: .short)))
                        .font(.system(size: 9)).foregroundColor(.secondary)
                }
            }
            .padding(12)

            ForEach(MacInfoCatalog.categories) { category in
                Divider()
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedGroups.contains(category.id) },
                        set: { newValue in
                            if newValue {
                                expandedGroups.insert(category.id)
                                Task { await model.load(category) }
                            } else {
                                expandedGroups.remove(category.id)
                            }
                        }
                    )
                ) {
                    categoryContents(category)
                        .padding(.top, 7)
                        .padding(.bottom, 5)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: category.symbol)
                            .foregroundColor(.secondary)
                            .frame(width: 17)
                        Text(LocalizedStringKey(category.titleKey))
                            .font(.system(size: 11, weight: .medium))
                        Spacer(minLength: 4)
                        if model.loading.contains(category.id) {
                            ProgressView().controlSize(.mini)
                        } else if let report = model.reports[category.id] {
                            Text("\(report.itemCount)")
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }

            Text("MACINFO_PRIVACY")
                .font(.system(size: 9)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 9)
        }
        .onAppear {
            Task {
                await model.load(MacInfoCatalog.categories[0])
                await model.load(MacInfoCatalog.categories[1])
            }
        }
    }

    @ViewBuilder
    private func categoryContents(_ category: MacInfoCategory) -> some View {
        if model.loading.contains(category.id) {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("MACINFO_LOADING")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
        } else if let report = model.reports[category.id] {
            if let error = report.error {
                Text(LocalizedStringKey(error))
                    .font(.system(size: 10)).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("MACINFO_RETRY") {
                    Task { await model.load(category, force: true) }
                }
                .buttonStyle(.bordered).controlSize(.small)
            } else {
                let sources = matchingSources(report)
                if sources.isEmpty {
                    Text(searchText.isEmpty ? "MACINFO_EMPTY" : "MACINFO_NO_MATCH")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(sources) { source in
                            DisclosureGroup(
                                isExpanded: Binding(
                                    get: {
                                        expandedSources.contains(source.id) ||
                                        (!searchText.isEmpty && source.items.count < 100)
                                    },
                                    set: { value in
                                        if value { expandedSources.insert(source.id) }
                                        else { expandedSources.remove(source.id) }
                                    }
                                )
                            ) {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(source.items) { item in
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.name)
                                                .font(.system(size: 9))
                                                .foregroundColor(.secondary)
                                                .textSelection(.enabled)
                                            Text(item.value)
                                                .font(.system(size: 11))
                                                .textSelection(.enabled)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 5)
                                        Divider().opacity(0.4)
                                    }
                                }
                                .padding(.leading, 9)
                            } label: {
                                HStack {
                                    Text(source.name)
                                        .font(.system(size: 10, weight: .semibold))
                                    Spacer()
                                    Text("\(source.items.count)")
                                        .font(.system(size: 9).monospacedDigit())
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        } else {
            Text("MACINFO_TAP_TO_LOAD")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    private func matchingSources(_ report: MacInfoReport) -> [MacInfoSource] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return report.sources }
        return report.sources.compactMap { source in
            if source.name.localizedCaseInsensitiveContains(needle) { return source }
            let matches = source.items.filter {
                $0.name.localizedCaseInsensitiveContains(needle) ||
                $0.value.localizedCaseInsensitiveContains(needle)
            }
            return matches.isEmpty ? nil :
                MacInfoSource(id: source.id, name: source.name, items: matches)
        }
    }
}
#endif
