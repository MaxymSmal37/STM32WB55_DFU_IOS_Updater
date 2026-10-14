//
//  DeviceInfoView.swift
//  STM32WB55_OTA_Updater
//
//  Created by Maxym Smal on 14.10.2026.
//
import SwiftUI
import CoreBluetooth
import UniformTypeIdentifiers

struct DeviceInfoView: View {
    @ObservedObject var ble: BluetoothManager

    // Firmware file
    @State private var showImporter = false
    @State private var firmwareName: String?
    @State private var firmwareData: Data?

    // Update state
    @State private var isUpdating = false
    @State private var progress: Double = 0
    @State private var statusText = "Idle"
    @State private var updateTask: Task<Void, Never>?

    @State private var errorText: String?

    // .bin files, or any file if the type is unknown
    private var firmwareTypes: [UTType] {
        [UTType(filenameExtension: "bin"), .data].compactMap { $0 }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    deviceCard
                    firmwareCard
                    updateCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(ble.connectedPeripheral?.name ?? "Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Disconnect", role: .destructive) {
                        cancelUpdate()
                        ble.disconnect()
                    }
                    .disabled(isUpdating)
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: firmwareTypes,
                          allowsMultipleSelection: false) { result in
                handleImport(result)
            }
            .alert("ERROR",
                   isPresented: Binding(get: { errorText != nil },
                                        set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
            .onDisappear { cancelUpdate() }
        }
    }

    // MARK: - Cards

    private var deviceCard: some View {
        Card(title: "Device Information", systemImage: "cpu") {
            InfoRow(label: "FW version", value: ble.fwVersion)
            Divider()
            InfoRow(label: "Device S/N", value: ble.serialNumber)
            Divider()
            InfoRow(label: "MCU ID", value: ble.mcuId)
        }
    }

    private var firmwareCard: some View {
        Card(title: "Firmware File", systemImage: "doc.badge.arrow.up") {
            if let name = firmwareName, let data = firmwareData {
                InfoRow(label: "File", value: name)
                Divider()
                InfoRow(label: "Size", value: ByteCountFormatter.string(fromByteCount: Int64(data.count),
                                                                           countStyle: .file))
            } else {
                Text("No file selected")
                    .foregroundStyle(.secondary)
            }

            Button {
                showImporter = true
            } label: {
                Label(firmwareData == nil ? "Choose File" : "Change File",
                      systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isUpdating)
        }
    }

    private var updateCard: some View {
        Card(title: "Firmware Update", systemImage: "arrow.triangle.2.circlepath") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(statusText)
                        .font(.subheadline)
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: progress)
                    .tint(progress >= 1 ? .green : .accentColor)
            }
            .opacity(isUpdating || progress > 0 ? 1 : 0.4)

            HStack(spacing: 12) {
                Button {
                    startUpdate()
                } label: {
                    Label("Update", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(firmwareData == nil || isUpdating)

                if isUpdating {
                    Button(role: .destructive) {
                        cancelUpdate()
                        statusText = "Cancelled"
                    } label: {
                        Text("Cancel")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Logic

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                firmwareData = try Data(contentsOf: url)
                firmwareName = url.lastPathComponent
                progress = 0
                statusText = "File ready"
            } catch {
                errorText = "Failed to read file: \(error.localizedDescription)"
            }
        case .failure(let error):
            errorText = error.localizedDescription
        }
    }

    private func startUpdate() {
        guard let data = firmwareData else { return }
        isUpdating = true
        progress = 0
        statusText = "Preparing…"

        updateTask = Task {
            // TODO: replace this loop with a real BLE transfer.
            // For example: ble.sendFirmware(data) { sent in progress = Double(sent) / Double(data.count) }
            let total = data.count
            let chunk = max(total / 100, 1)
            var sent = 0
            while sent < total {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 30_000_000)
                sent = min(sent + chunk, total)
                progress = Double(sent) / Double(total)
                statusText = "Transferring data…"
            }
            statusText = "Update complete"
            isUpdating = false
        }
    }

    private func cancelUpdate() {
        updateTask?.cancel()
        updateTask = nil
        isUpdating = false
    }
}

// MARK: - Helper views

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
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
