//
//  DeviceInfoView.swift
//  STM32WB55_OTA_Updater
//
//  Created by Maxym Smal on 14.10.2026.
//
import Foundation
import Combine
import SwiftUI
import CoreBluetooth

struct DeviceInfoView: View {
   @ObservedObject var ble: BluetoothManager

   var body: some View {
       NavigationStack {
           VStack(alignment: .leading, spacing: 6) {
               Text("FW version: \(ble.fwVersion)")
               Text("Device S/N: \(ble.serialNumber)")
               Text("MCU ID:     \(ble.mcuId)")
           }
           .font(.system(.body, design: .monospaced))
           .padding(12)
           .background(Color(.secondarySystemBackground),
                       in: RoundedRectangle(cornerRadius: 8))
           .padding()
           .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
           .navigationTitle(ble.connectedPeripheral?.name ?? "Device")
           .navigationBarTitleDisplayMode(.inline)
           .toolbar {
               ToolbarItem(placement: .topBarTrailing) {
                   Button("Disconnect", role: .destructive) { ble.disconnect() }
               }
           }
       }
   }
}
