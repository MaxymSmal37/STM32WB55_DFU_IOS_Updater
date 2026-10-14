//
//  BluetoothManager.swift
//  STM32WB55_OTA_Updater
//

import Foundation
import Combine
import CoreBluetooth

final class BluetoothManager: NSObject, ObservableObject {

    private let companyID: [UInt8] = [0x23, 0x23]
    private let marker: [UInt8]    = [0x4D, 0x58]   // "MX"
    private let deviceType: UInt8  = 0x01
    // MARK: - UUID кастомного сервісу SysInfo
    // ЗАМІНИ на значення з custom_stm.c (або з nRF Connect)
    private let sysInfoService = CBUUID(string: "00000001-CC7A-482A-984A-7F2ED5B3E58F")
    private let fwVersionChar  = CBUUID(string: "00000010-8E22-4541-9D4C-21EDAE82ED19") // Bootloader_Fw_Ver, 5 байт
    private let mcuIdChar      = CBUUID(string: "00000100-8E22-4541-9D4C-21EDAE82ED19") // MCU_ID, 4 байти
    private let serialNumChar  = CBUUID(string: "00000000-8E22-4541-9D4C-21EDAE82ED19") // Device_SN, 4 байти

    private var central: CBCentralManager!

    @Published var devices: [DiscoveredPeripheral] = []
    @Published var isScanning = false
    @Published var isConnecting = false
    @Published var connectedPeripheral: CBPeripheral?
    @Published var errorMessage: String?

    @Published var fwVersion = "—"
    @Published var serialNumber = "—"
    @Published var mcuId = "—"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Керування

    func startScan() {
        switch central.state {
        case .poweredOn:
            break
        case .unknown, .resetting:
            errorMessage = "Bluetooth ще ініціалізується, спробуйте ще раз"
            return
        case .unsupported:
            errorMessage = "Bluetooth не підтримується (симулятор?). Запустіть на реальному iPhone"
            return
        case .unauthorized:
            errorMessage = "Немає дозволу на Bluetooth. Дозвольте в Налаштуваннях"
            return
        case .poweredOff:
            errorMessage = "Bluetooth вимкнений. Увімкніть його"
            return
        @unknown default:
            errorMessage = "Невідомий стан Bluetooth"
            return
        }

        devices.removeAll()
        isScanning = true
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
    }

    func connect(_ device: DiscoveredPeripheral) {
        stopScan()
        isConnecting = true
        central.connect(device.peripheral, options: nil)
    }

    func disconnect() {
        if let p = connectedPeripheral {
            central.cancelPeripheralConnection(p)
        }
    }

    private func resetInfo() {
        fwVersion = "—"
        serialNumber = "—"
        mcuId = "—"
    }

    // MARK: - Розбір сирих байтів

    /// 5 байт: якщо всі символи друковані ASCII ("1.0.0") — показуємо як текст, інакше hex.
    private func parseFwVersion(_ data: Data) -> String {
        guard data.count >= 2 else {
            return data.map { String(format: "%02X", $0) }.joined(separator: " ")
        }

        let prefix = String(decoding: data.prefix(2), as: UTF8.self)
        let numbers = data.dropFirst(2).map { String($0) }.joined(separator: ".")

        return numbers.isEmpty ? prefix : "\(prefix) \(numbers)"
    }

    /// 4 байти як uint32 (little-endian, як у STM32).
    private func uint32LE(_ data: Data) -> UInt32? {
        guard data.count >= 4 else { return nil }
        return data.prefix(4).enumerated().reduce(UInt32(0)) { acc, pair in
            acc | (UInt32(pair.element) << (8 * UInt32(pair.offset)))
        }
    }
    
    private func isMyDevice(_ adv: [String: Any]) -> Bool {
        guard let data = adv[CBAdvertisementDataManufacturerDataKey] as? Data,
              data.count >= 5 else { return false }
        let b = [UInt8](data)
        return Array(b[0..<2]) == companyID
            && Array(b[2..<4]) == marker
            && b[4] == deviceType
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            isScanning = false
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        
        guard isMyDevice(advertisementData) else { return }
        
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "Unknown"

        if let idx = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            devices[idx].rssi = RSSI.intValue
        } else {
            devices.append(.init(id: peripheral.identifier,
                                 peripheral: peripheral,
                                 name: name,
                                 rssi: RSSI.intValue))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        resetInfo()
        peripheral.delegate = self
        // nil = знайти ВСІ сервіси (для логів). Коли UUID вже правильні, можна замінити на [sysInfoService]
        peripheral.discoverServices(nil)
        isConnecting = false
        connectedPeripheral = peripheral   // → відкриває друге вікно
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        isConnecting = false
        errorMessage = "Не вдалося підключитись: \(error?.localizedDescription ?? "unknown")"
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        connectedPeripheral = nil          // → закриває друге вікно
        resetInfo()
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        peripheral.services?.forEach {
            print("🔹 Service: \($0.uuid)")
            peripheral.discoverCharacteristics(nil, for: $0)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        service.characteristics?.forEach { ch in
            print("   ▫️ Characteristic: \(ch.uuid)")
            if [fwVersionChar, mcuIdChar, serialNumChar].contains(ch.uuid) {
                peripheral.readValue(for: ch)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let data = characteristic.value else { return }
        print("   ✅ \(characteristic.uuid) = \(data.map { String(format: "%02X", $0) }.joined())")

        switch characteristic.uuid {
        case fwVersionChar:
            fwVersion = parseFwVersion(data)
        case mcuIdChar:
            mcuId = uint32LE(data).map { String(format: "0x%08X", $0) } ?? "—"
        case serialNumChar:
            serialNumber = uint32LE(data).map { String(format: "%08X", $0) } ?? "—"
        default:
            break
        }
    }
}
