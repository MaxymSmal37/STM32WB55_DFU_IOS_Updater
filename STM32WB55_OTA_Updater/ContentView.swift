//
//  ContentView.swift
//  STM32WB55_OTA_Updater
//
//  Created by Maxym Smal on 14.10.2026.
//

import CoreBluetooth
import SwiftUI

struct ContentView: View {
    @StateObject private var ble = BluetoothManager()
    @State private var activeDevice: DiscoveredPeripheral?

    var body: some View {
        NavigationStack {
            List(ble.devices) { device in
                Button {
                    ble.connect(device)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(device.name).font(.headline)
                            Text(device.id.uuidString)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(device.rssi) dBm")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(ble.isConnecting)
            }
            .overlay {
                if ble.devices.isEmpty {
                    ContentUnavailableView(
                        ble.isScanning ? "Scanning for devices…" : "No devices found",
                        systemImage: "dot.radiowaves.left.and.right"
                    )
                }
                if ble.isConnecting {
                    ProgressView("Connecting…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .navigationTitle("Bluetooth")
            .toolbar {
                Button(ble.isScanning ? "Stop" : "Scan") {
                    ble.isScanning ? ble.stopScan() : ble.startScan()
                }
                .disabled(ble.isConnecting)
            }
            .alert("ERROR",
                   isPresented: Binding(get: { ble.errorMessage != nil },
                                        set: { if !$0 { ble.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(ble.errorMessage ?? "")
            }
        }
        .onChange(of: ble.connectedPeripheral?.identifier) { _, identifier in
            if let identifier, let device = ble.devices.first(where: { $0.id == identifier }) {
                activeDevice = device
            }
        }
        .fullScreenCover(item: $activeDevice) { device in
            DeviceInfoView(ble: ble, device: device) {
                activeDevice = nil
            }
        }
    }
}

#Preview {
    ContentView()
}
