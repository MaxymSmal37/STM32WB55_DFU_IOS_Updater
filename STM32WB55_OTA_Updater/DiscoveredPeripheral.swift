//
//  DiscoveredPeripheral.swift
//  STM32WB55_OTA_Updater
//
//  Created by Maxym Smal on 14.10.2026.
//

import CoreBluetooth
 
struct DiscoveredPeripheral: Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int
}
 
