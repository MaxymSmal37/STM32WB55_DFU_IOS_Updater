import CoreBluetooth
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct DeviceInfoView: View {
    @ObservedObject var ble: BluetoothManager
    @StateObject private var updater: OTAUpdater
    let device: DiscoveredPeripheral
    let onClose: () -> Void

    @State private var showImporter = false
    @State private var showStartConfirmation = false
    @State private var firmwareName: String?
    @State private var errorText: String?
    @State private var diagnosticsExpanded = false

    private let firmwareTypes: [UTType] = [UTType(filenameExtension: "bin"), .data].compactMap { $0 }

    init(ble: BluetoothManager, device: DiscoveredPeripheral, onClose: @escaping () -> Void) {
        self.ble = ble
        self.device = device
        self.onClose = onClose
        let updater = OTAUpdater(transport: ble)
        _updater = StateObject(wrappedValue: updater)
    }

    private var isUpdating: Bool { updater.isUpdating }
    private var allLogEntries: [String] { ble.logLines + updater.log }
    private var recentLogEntries: [String] { Array(allLogEntries.suffix(200)) }
    private var logText: String { recentLogEntries.joined(separator: "\n") }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    deviceCard
                    diagnosticsCard
                    firmwareCard
                    updateCard
                    logCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(ble.connectedPeripheral?.name ?? device.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if ble.connectedPeripheral != nil {
                        Button("Disconnect", role: .destructive) {
                            ble.disconnect()
                        }
                        .disabled(isUpdating || ble.isConnecting)
                    } else {
                        Button("Close", action: onClose)
                    }
                }
            }
            .interactiveDismissDisabled(isUpdating)
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: firmwareTypes,
                allowsMultipleSelection: false,
                onCompletion: handleImport
            )
            .confirmationDialog(
                "Do not disconnect or close the app during the firmware update.",
                isPresented: $showStartConfirmation,
                titleVisibility: .visible
            ) {
                Button("Start Update", role: .destructive) {
                    updater.start()
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Error", isPresented: Binding(
                get: { errorText != nil || updater.firmwareLoadError != nil },
                set: {
                    if !$0 {
                        errorText = nil
                        updater.clearFirmwareLoadError()
                    }
                }
            )) {
                Button("OK", role: .cancel) { errorText = nil }
            } message: {
                Text(errorText ?? updater.firmwareLoadError ?? "An unknown error occurred.")
            }
            .onDisappear {
                if updater.isUpdating { updater.cancel() }
                if ble.otaUpdater === updater { ble.otaUpdater = nil }
            }
            .onAppear {
                ble.otaUpdater = updater
            }
        }
    }

    private var deviceCard: some View {
        Card(title: "Device Information", systemImage: "cpu") {
            InfoRow(label: "FW version", value: ble.fwVersion, isSuspect: ble.fwVersionIsSuspect)
            Divider()
            InfoRow(label: "Wireless FW info", value: ble.wirelessFwInfo, isSuspect: ble.wirelessFwInfoIsSuspect)
            Divider()
            InfoRow(label: "Serial number", value: ble.serialNumber, isSuspect: ble.serialNumberIsSuspect)
            Divider()
            InfoRow(label: "HW revision", value: ble.hardwareRevision, isSuspect: ble.hardwareRevisionIsSuspect)
            if ble.connectedPeripheral == nil {
                Divider()
                HStack {
                    Text(ble.isConnecting ? "Connecting…" : "Connection lost")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reconnect") {
                        ble.connect(device)
                    }
                    .disabled(ble.isConnecting)
                }
            }
        }
    }

    private var diagnosticsCard: some View {
        Card(title: "Connection diagnostics", systemImage: "waveform.path") {
            DisclosureGroup("Show connection diagnostics", isExpanded: $diagnosticsExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    InfoRow(
                        label: "Write without response",
                        value: ble.maxWriteNoResp.map { "\($0) bytes" } ?? "Not connected"
                    )
                    InfoRow(
                        label: "Write with response",
                        value: ble.maxWriteWithResp.map { "\($0) bytes" } ?? "Not connected"
                    )
                    InfoRow(
                        label: "Batch payload",
                        value: ble.batchPayloadSize.map { "\($0) bytes" } ?? "Not available"
                    )
                    Divider()
                    InfoRow(label: "CMD characteristic", value: ble.hasCommandCharacteristic ? "✅ Found" : "❌ Not found")
                    InfoRow(label: "DATA characteristic", value: ble.hasDataCharacteristic ? "✅ Found" : "❌ Not found")
                    InfoRow(label: "STATUS characteristic", value: ble.hasStatusCharacteristic ? "✅ Found" : "❌ Not found")
                    InfoRow(label: "STATUS notifications", value: ble.isStatusNotifying ? "✅ Enabled" : "❌ Disabled")
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Services found")
                            .foregroundStyle(.secondary)
                        Text(ble.servicesFound.isEmpty ? "None" : ble.servicesFound.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private var firmwareCard: some View {
        Card(title: "Firmware File", systemImage: "doc.badge.arrow.up") {
            if let image = updater.selectedFirmware, let firmwareName {
                InfoRow(label: "File", value: firmwareName)
                Divider()
                InfoRow(
                    label: "Size",
                    value: ByteCountFormatter.string(fromByteCount: Int64(image.size), countStyle: .file)
                )
                Divider()
                InfoRow(label: "SHA-256", value: String(image.sha256.map { String(format: "%02x", $0) }.joined().prefix(8)))
            } else {
                Text(firmwareName == nil ? "No file selected" : "Calculating SHA-256…")
                    .foregroundStyle(.secondary)
            }

            Button {
                showImporter = true
            } label: {
                Label(firmwareName == nil ? "Choose File" : "Change File", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isUpdating)
        }
    }

    private var updateCard: some View {
        Card(title: "Firmware Update", systemImage: "arrow.triangle.2.circlepath") {
            if ble.maxWriteNoResp == 20 {
                Label(
                    "MTU is 23. Firmware must raise CFG_BLE_MAX_ATT_MTU. Transfer will be slow.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Text(updater.phase.title)
                        .font(.subheadline)
                    Spacer(minLength: 8)
                    Text("\(Int(updater.progress * 100))%")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: updater.progress)
                    .tint(updater.phase == .done ? .green : .accentColor)
                InfoRow(
                    label: "Bytes",
                    value: "\(ByteCountFormatter.string(fromByteCount: Int64(updater.bytesSent), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(updater.totalBytes), countStyle: .file))"
                )
                InfoRow(label: "Speed", value: String(format: "%.1f KB/s", updater.speedBytesPerSec / 1_024))
                InfoRow(label: "ETA", value: etaText)
            }
            .opacity(isUpdating || updater.progress > 0 ? 1 : 0.6)

            HStack(spacing: 12) {
                Button {
                    showStartConfirmation = true
                } label: {
                    Label("Update", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(updateDisabledReason != nil || isUpdating)

                if isUpdating {
                    Button("Cancel", role: .destructive) {
                        updater.cancel()
                    }
                    .buttonStyle(.bordered)
                }
            }

            if let updateDisabledReason, !isUpdating {
                Text(updateDisabledReason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if case .failed = updater.phase {
                Button("Retry") {
                    if ble.isOTAReady {
                        updater.start()
                    } else if ble.connectedPeripheral == nil {
                        ble.connect(device)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(ble.isConnecting || (ble.connectedPeripheral != nil && !ble.isOTAReady))
            }
            Text("Keep the app in the foreground. Do not disconnect during the update.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var updateDisabledReason: String? {
        if updater.selectedFirmware == nil { return "Select a firmware file to enable Update." }
        guard ble.connectedPeripheral != nil else { return "Connect to the device to enable Update." }
        if !ble.hasCommandCharacteristic { return "Waiting for the CMD characteristic." }
        if !ble.hasDataCharacteristic { return "Waiting for the DATA characteristic." }
        if !ble.hasStatusCharacteristic { return "Waiting for the STATUS characteristic." }
        if !ble.isStatusNotifying { return "Waiting for STATUS notifications to be enabled." }
        if !ble.isOTAReady { return "Waiting for the BLE connection to become ready." }
        return nil
    }

    private var logCard: some View {
        Card(title: "Log", systemImage: "text.alignleft") {
            if recentLogEntries.isEmpty {
                Text("No activity yet.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(logText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
            }
            HStack {
                Button {
                    UIPasteboard.general.string = logText
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(recentLogEntries.isEmpty)
                ShareLink(item: logText) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(recentLogEntries.isEmpty)
            }
            .buttonStyle(.bordered)
        }
    }

    private var etaText: String {
        guard let eta = updater.eta, eta.isFinite else { return "—" }
        let seconds = max(Int(eta.rounded()), 0)
        return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let hasAccess = url.startAccessingSecurityScopedResource()
            Task {
                defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try await Task.detached(priority: .userInitiated) {
                        try Data(contentsOf: url)
                    }.value
                    firmwareName = url.lastPathComponent
                    updater.selectFirmware(data)
                } catch {
                    errorText = "Could not read the firmware file: \(error.localizedDescription)"
                }
            }
        case .failure(let error):
            errorText = error.localizedDescription
        }
    }
}

private struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    var isSuspect = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .foregroundStyle(.secondary)
                Spacer()
                if isSuspect {
                    Text("⚠️")
                        .accessibilityLabel("Suspect value")
                }
                Text(value)
                    .font(.system(.body, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            if isSuspect {
                Text("Value looks uninitialized (firmware bug)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
