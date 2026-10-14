//
//  ContentView.swift
//  STM32WB55_OTA_Updater
//
//  Created by Maxym Smal on 14.10.2026.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var ble = BluetoothManager()

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
                        ble.isScanning ? "Пошук пристроїв…" : "Пристроїв немає",
                        systemImage: "dot.radiowaves.left.and.right"
                    )
                }
                if ble.isConnecting {
                    ProgressView("Connection…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .navigationTitle("Bluetooth")
            .toolbar {
                Button(ble.isScanning ? "Stop" : "Finding") {
                    ble.isScanning ? ble.stopScan() : ble.startScan()
                }
            }
            .alert("ERROR",
                   isPresented: Binding(get: { ble.errorMessage != nil },
                                        set: { if !$0 { ble.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(ble.errorMessage ?? "")
            }
        }
        // Друге вікно відкривається після успішного підключення
        .fullScreenCover(isPresented: Binding(
            get: { ble.connectedPeripheral != nil },
            set: { if !$0 { ble.disconnect() } }
        )) {
            DeviceInfoView(ble: ble)
        }
    }
}

#Preview {
    ContentView()
}
