import Combine
import CoreBluetooth
import Foundation

@MainActor
final class BluetoothManager: NSObject, ObservableObject {
    private enum PendingKind {
        case command
        case batch
    }

    private var central: CBCentralManager?
    private var commandCharacteristic: CBCharacteristic?
    private var dataCharacteristic: CBCharacteristic?
    private var statusCharacteristic: CBCharacteristic?
    private var serialCharacteristic: CBCharacteristic?
    private var hardwareRevisionCharacteristic: CBCharacteristic?
    private var pendingStatus: CheckedContinuation<OTAStatus, Error>?
    private var pendingKind: PendingKind?
    private var pendingWrite: CheckedContinuation<Void, Error>?
    private var flowContinuation: CheckedContinuation<Void, Error>?
    private var statusTimeoutTask: Task<Void, Never>?
    private var writeTimeoutTask: Task<Void, Never>?
    private var flowTimeoutTask: Task<Void, Never>?
    private var activeOperationTask: Task<Void, Never>?
    private var mtuRefreshTask: Task<Void, Never>?
    weak var otaUpdater: OTAUpdater?

    @Published var devices: [DiscoveredPeripheral] = []
    @Published var isScanning = false
    @Published var isConnecting = false
    @Published var connectedPeripheral: CBPeripheral?
    @Published var errorMessage: String?
    @Published var logLines: [String] = []
    @Published var fwVersion = "—"
    @Published var wirelessFwInfo = "—"
    @Published var serialNumber = "—"
    @Published var hardwareRevision = "—"
    @Published var fwVersionIsSuspect = false
    @Published var wirelessFwInfoIsSuspect = false
    @Published var serialNumberIsSuspect = false
    @Published var hardwareRevisionIsSuspect = false
    @Published private(set) var maxWriteNoResp: Int?
    @Published private(set) var maxWriteWithResp: Int?
    @Published private(set) var batchPayloadSize: Int?
    @Published private(set) var servicesFound: [String] = []
    @Published private(set) var hasCommandCharacteristic = false
    @Published private(set) var hasCommandNotifyProperty = false
    @Published private(set) var hasDataCharacteristic = false
    @Published private(set) var hasStatusCharacteristic = false
    @Published private(set) var isCommandNotifying = false
    @Published private(set) var isStatusNotifying = false

    var isOTAReady: Bool {
        guard let peripheral = connectedPeripheral,
              peripheral.state == .connected,
              hasCommandCharacteristic,
              isCommandNotifying,
              hasDataCharacteristic,
              hasStatusCharacteristic,
              isStatusNotifying else {
            return false
        }
        return true
    }

    var isReady: Bool { isOTAReady }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        guard let central else { return }
        switch central.state {
        case .poweredOn:
            break
        case .unknown, .resetting:
            errorMessage = "Bluetooth is initializing. Try again shortly."
            return
        case .unsupported:
            errorMessage = "Bluetooth is not supported. Use a physical iPhone."
            return
        case .unauthorized:
            errorMessage = "Bluetooth permission is unavailable. Check Settings."
            return
        case .poweredOff:
            errorMessage = "Bluetooth is turned off. Turn it on and try again."
            return
        @unknown default:
            errorMessage = "Bluetooth is in an unknown state."
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
        central?.stopScan()
        isScanning = false
    }

    func connect(_ device: DiscoveredPeripheral) {
        stopScan()
        isConnecting = true
        central?.connect(device.peripheral, options: nil)
    }

    func disconnect() {
        if let peripheral = connectedPeripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
    }

    private func resetConnectionState() {
        mtuRefreshTask?.cancel()
        mtuRefreshTask = nil
        fwVersion = "—"
        wirelessFwInfo = "—"
        serialNumber = "—"
        hardwareRevision = "—"
        fwVersionIsSuspect = false
        wirelessFwInfoIsSuspect = false
        serialNumberIsSuspect = false
        hardwareRevisionIsSuspect = false
        commandCharacteristic = nil
        dataCharacteristic = nil
        statusCharacteristic = nil
        serialCharacteristic = nil
        hardwareRevisionCharacteristic = nil
        maxWriteNoResp = nil
        maxWriteWithResp = nil
        batchPayloadSize = nil
        servicesFound.removeAll()
        hasCommandCharacteristic = false
        hasCommandNotifyProperty = false
        hasDataCharacteristic = false
        hasStatusCharacteristic = false
        isCommandNotifying = false
        isStatusNotifying = false
    }

    func refreshLinkParameters() {
        guard let peripheral = connectedPeripheral,
              peripheral.state == .connected else {
            return
        }

        let updatedMaxWriteNoResp = peripheral.maximumWriteValueLength(for: .withoutResponse)
        let updatedMaxWriteWithResp = peripheral.maximumWriteValueLength(for: .withResponse)
        let updatedBatchPayloadSize = STM32WB55_OTA_Updater.batchPayloadSize(
            maxWriteNoResp: updatedMaxWriteNoResp
        )
        let didChange = maxWriteNoResp != updatedMaxWriteNoResp
            || maxWriteWithResp != updatedMaxWriteWithResp
            || batchPayloadSize != updatedBatchPayloadSize

        maxWriteNoResp = updatedMaxWriteNoResp
        maxWriteWithResp = updatedMaxWriteWithResp
        batchPayloadSize = updatedBatchPayloadSize

        if didChange {
            log(
                "Link parameters: maxWriteNoResp \(updatedMaxWriteNoResp), "
                    + "maxWriteWithResp \(updatedMaxWriteWithResp), "
                    + "batch payload \(updatedBatchPayloadSize) B"
            )
        }
    }

    private func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logLines.append("[\(formatter.string(from: Date()))] \(message)")
        if logLines.count > 200 {
            logLines.removeFirst(logLines.count - 200)
        }
    }

    private func isMyDevice(_ advertisement: [String: Any]) -> Bool {
        guard let data = advertisement[CBAdvertisementDataManufacturerDataKey] as? Data,
              data.count >= 5 else { return false }
        let bytes = [UInt8](data)
        return Array(bytes[0..<2]) == BLEConstants.companyID
            && Array(bytes[2..<4]) == BLEConstants.manufacturerMarker
            && bytes[4] == BLEConstants.deviceType
    }

    private func displayValue(_ data: Data) -> (text: String, isSuspect: Bool) {
        let suspect = looksUninitialized(data)
        var bytes = [UInt8](data)
        while bytes.last == 0 {
            bytes.removeLast()
        }
        let text: String
        if !bytes.isEmpty, bytes.allSatisfy({ (0x20...0x7E).contains($0) }) {
            text = String(decoding: bytes, as: UTF8.self)
        } else {
            text = rawHex(data)
        }
        return (text.isEmpty ? (data.isEmpty ? "—" : rawHex(data)) : text, suspect)
    }

    private func looksUninitialized(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        if data.allSatisfy({ $0 == 0 }) || data.allSatisfy({ $0 == 0xFF }) {
            return true
        }
        let bytes = [UInt8](data)
        for offset in stride(from: 0, through: bytes.count - 4, by: 4) {
            let word = UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
            if (0x20000000...0x2002FFFF).contains(word)
                || (0x08000000...0x080FFFFF).contains(word) {
                return true
            }
        }
        return false
    }

    private func rawHex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func failPendingOperations(with error: Error) {
        finishStatus(.failure(error))
        finishWrite(.failure(error))
        finishFlow(.failure(error))
    }

    private func finishStatus(_ result: Result<OTAStatus, Error>) {
        guard let continuation = pendingStatus else { return }
        pendingStatus = nil
        pendingKind = nil
        statusTimeoutTask?.cancel()
        statusTimeoutTask = nil
        switch result {
        case .success:
            finishWrite(.success(()))
        case .failure(let error):
            finishWrite(.failure(error))
            finishFlow(.failure(error))
        }
        let operationTask = activeOperationTask
        activeOperationTask = nil
        operationTask?.cancel()
        continuation.resume(with: result)
    }

    private func finishWrite(_ result: Result<Void, Error>) {
        guard let continuation = pendingWrite else { return }
        pendingWrite = nil
        writeTimeoutTask?.cancel()
        writeTimeoutTask = nil
        continuation.resume(with: result)
    }

    private func finishFlow(_ result: Result<Void, Error>) {
        guard let continuation = flowContinuation else { return }
        flowContinuation = nil
        flowTimeoutTask?.cancel()
        flowTimeoutTask = nil
        continuation.resume(with: result)
    }

    private func writeCommand(_ frame: Data, timeout: TimeInterval) async throws {
        guard let peripheral = connectedPeripheral,
              let commandCharacteristic,
              commandCharacteristic.properties.contains(.write)
                || commandCharacteristic.properties.contains(.writeWithoutResponse) else {
            throw OTAOperationError.notReady
        }
        let isWriteWithResponse = commandCharacteristic.properties.contains(.write)
        let writeLimit = isWriteWithResponse
            ? maxWriteWithResp
            : maxWriteNoResp
        guard let writeLimit else { throw OTAOperationError.notReady }
        let availableLength = min(writeLimit, BLEConstants.cmdCharacteristicLength)
        guard frame.count <= availableLength else {
            throw OTAOperationError.insufficientWriteLength(
                required: frame.count,
                available: availableLength
            )
        }
        log("CMD TX \(isWriteWithResponse ? "with response" : "without response"): \(rawHex(frame))")
        if !isWriteWithResponse {
            try await waitUntilCanWriteWithoutResponse(peripheral: peripheral, timeout: timeout)
            peripheral.writeValue(frame, for: commandCharacteristic, type: .withoutResponse)
            log("CMD write submitted without response; MCU receipt is not confirmed by BLE")
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard pendingWrite == nil else {
                    continuation.resume(throwing: OTAOperationError.notReady)
                    return
                }
                pendingWrite = continuation
                writeTimeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(timeout))
                    } catch {
                        return
                    }
                    self?.finishWrite(.failure(OTAOperationError.timeout))
                }
                peripheral.writeValue(frame, for: commandCharacteristic, type: .withResponse)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishWrite(.failure(CancellationError())) }
        }
    }

    private func waitUntilCanWriteWithoutResponse(
        peripheral: CBPeripheral,
        timeout: TimeInterval
    ) async throws {
        if peripheral.canSendWriteWithoutResponse { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard flowContinuation == nil else {
                    continuation.resume(throwing: OTAOperationError.notReady)
                    return
                }
                flowContinuation = continuation
                flowTimeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(timeout))
                    } catch {
                        return
                    }
                    self?.finishFlow(.failure(OTAOperationError.timeout))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishFlow(.failure(CancellationError())) }
        }
    }

    private func sendAndWaitForStatus(
        _ frame: Data,
        timeout: TimeInterval,
        isCommand: Bool
    ) async throws -> OTAStatus {
        guard isOTAReady, let peripheral = connectedPeripheral else {
            throw OTAOperationError.notReady
        }
        if isCommand {
            guard let commandCharacteristic else { throw OTAOperationError.notReady }
            let writeLimit = commandCharacteristic.properties.contains(.write)
                ? maxWriteWithResp
                : commandCharacteristic.properties.contains(.writeWithoutResponse)
                    ? maxWriteNoResp
                    : nil
            guard let writeLimit else { throw OTAOperationError.notReady }
            let availableLength = min(writeLimit, BLEConstants.cmdCharacteristicLength)
            guard frame.count <= availableLength else {
                throw OTAOperationError.insufficientWriteLength(
                    required: frame.count,
                    available: availableLength
                )
            }
        } else {
            guard let maxWriteNoResp else { throw OTAOperationError.notReady }
            guard frame.count <= maxWriteNoResp,
                  frame.count <= BLEConstants.dataCharacteristicLength else {
                throw OTAOperationError.frameLargerThanLinkLimit
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OTAStatus, Error>) in
                guard pendingStatus == nil else {
                    continuation.resume(throwing: OTAOperationError.notReady)
                    return
                }
                pendingStatus = continuation
                pendingKind = isCommand ? .command : .batch
                statusTimeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(timeout))
                    } catch {
                        return
                    }
                    self?.finishStatus(.failure(OTAOperationError.timeout))
                }
                activeOperationTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        if isCommand {
                            try await self.writeCommand(frame, timeout: BLEConstants.writeTimeout)
                        } else {
                            try await self.waitUntilCanWriteWithoutResponse(
                                peripheral: peripheral,
                                timeout: BLEConstants.writeTimeout
                            )
                            guard let dataCharacteristic = self.dataCharacteristic else {
                                throw OTAOperationError.notReady
                            }
                            guard let maxWriteNoResp = self.maxWriteNoResp,
                                  frame.count <= maxWriteNoResp,
                                  frame.count <= BLEConstants.dataCharacteristicLength else {
                                throw OTAOperationError.frameLargerThanLinkLimit
                            }
                            peripheral.writeValue(frame, for: dataCharacteristic, type: .withoutResponse)
                        }
                    } catch {
                        self.finishStatus(.failure(error))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishStatus(.failure(CancellationError())) }
        }
    }
}

extension BluetoothManager: OTATransport {
    func sendCommandAndWaitForStatus(_ frame: Data, timeout: TimeInterval) async throws -> OTAStatus {
        try await sendAndWaitForStatus(frame, timeout: timeout, isCommand: true)
    }

    func sendCommandAndWaitForWrite(_ frame: Data, timeout: TimeInterval) async throws -> OTAStatus? {
        guard isOTAReady else { throw OTAOperationError.notReady }
        try await writeCommand(frame, timeout: timeout)
        return nil
    }

    func sendBatchAndWaitForStatus(_ frame: Data, timeout: TimeInterval) async throws -> OTAStatus {
        try await sendAndWaitForStatus(frame, timeout: timeout, isCommand: false)
    }
}

extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn { isScanning = false }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard isMyDevice(advertisementData) else { return }
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "Unknown"
        if let index = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            devices[index].rssi = RSSI.intValue
        } else {
            devices.append(.init(
                id: peripheral.identifier,
                peripheral: peripheral,
                name: name,
                rssi: RSSI.intValue
            ))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        resetConnectionState()
        peripheral.delegate = self
        connectedPeripheral = peripheral
        isConnecting = false
        peripheral.discoverServices(nil)
        mtuRefreshTask = Task { [weak self, weak peripheral] in
            do {
                try await Task.sleep(for: .milliseconds(BLEConstants.mtuSettleDelayMs))
            } catch {
                return
            }
            guard let self, let peripheral,
                  self.connectedPeripheral === peripheral else {
                return
            }
            self.refreshLinkParameters()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        isConnecting = false
        errorMessage = "Connection failed: \(error?.localizedDescription ?? "unknown error")"
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        if otaUpdater?.isUpdating == true {
            otaUpdater?.connectionLost()
        }
        failPendingOperations(with: OTAOperationError.connectionLost)
        isConnecting = false
        connectedPeripheral = nil
        resetConnectionState()
        if let error { log("Disconnected: \(error.localizedDescription)") }
        else { log("Disconnected") }
    }
}

extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log("Service discovery failed: \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else {
            log("No services were discovered")
            return
        }
        for service in services {
            let uuid = service.uuid.uuidString
            servicesFound.append(uuid)
            log("Service discovered: \(uuid)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
        refreshLinkParameters()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            log("Characteristic discovery failed for \(service.uuid): \(error.localizedDescription)")
            return
        }
        let characteristics = service.characteristics ?? []
        for characteristic in characteristics {
            log("Characteristic discovered: \(characteristic.uuid)")
            if characteristic.uuid == BLEConstants.bootloaderFwVer
                || characteristic.uuid == BLEConstants.wirelessFwInfo {
                peripheral.readValue(for: characteristic)
            }
            if characteristic.uuid == BLEConstants.cmd {
                commandCharacteristic = characteristic
                hasCommandCharacteristic = true
                log("CMD properties: 0x\(String(characteristic.properties.rawValue, radix: 16))")
                if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                    hasCommandNotifyProperty = true
                    peripheral.setNotifyValue(true, for: characteristic)
                } else {
                    hasCommandNotifyProperty = false
                    log("CMD has no notify/indicate property: ACK cannot be received")
                }
            } else if characteristic.uuid == BLEConstants.data {
                dataCharacteristic = characteristic
                hasDataCharacteristic = true
            } else if characteristic.uuid == BLEConstants.status {
                statusCharacteristic = characteristic
                hasStatusCharacteristic = true
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }

        if characteristics.contains(where: { $0.uuid == BLEConstants.bootloaderFwVer }) {
            log("SysInfo characteristic group identified in service \(service.uuid)")
            resolveSysInfoCharacteristics(characteristics, peripheral: peripheral)
        }
        if characteristics.contains(where: { $0.uuid == BLEConstants.cmd }) {
            log("Transfer characteristic group identified in service \(service.uuid)")
        }
    }

    private func resolveSysInfoCharacteristics(
        _ characteristics: [CBCharacteristic],
        peripheral: CBPeripheral
    ) {
        let duplicatePair: (CBCharacteristic, CBCharacteristic)? = {
            guard characteristics.count > 3,
                  characteristics[2].uuid == characteristics[3].uuid else {
                return nil
            }
            return (characteristics[2], characteristics[3])
        }()

        if duplicatePair != nil {
            log("Firmware exposes duplicate UUIDs; mapping by index")
        }

        serialCharacteristic = characteristics.first(where: { $0.uuid == BLEConstants.serialNumber })
            ?? duplicatePair?.0
        hardwareRevisionCharacteristic = characteristics.first(where: {
            $0.uuid == BLEConstants.hardwareRevision
        }) ?? duplicatePair?.1

        if let serialCharacteristic {
            peripheral.readValue(for: serialCharacteristic)
        } else {
            log("Serial number characteristic was not found")
        }
        if let hardwareRevisionCharacteristic {
            peripheral.readValue(for: hardwareRevisionCharacteristic)
        } else {
            log("Hardware revision characteristic was not found")
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if characteristic === commandCharacteristic {
            isCommandNotifying = error == nil && characteristic.isNotifying
            log(isCommandNotifying
                ? "CMD notifications enabled"
                : "CMD notifications unavailable: \(error?.localizedDescription ?? "disabled")")
            return
        }
        guard characteristic === statusCharacteristic else { return }
        if let error {
            isStatusNotifying = false
            log("Could not enable STATUS notifications: \(error.localizedDescription)")
        } else {
            isStatusNotifying = characteristic.isNotifying
            log(characteristic.isNotifying
                ? "STATUS notifications enabled"
                : "STATUS notifications are disabled")
            if characteristic.isNotifying {
                refreshLinkParameters()
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            log("Read/update failed for \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else {
            log("No value returned for \(characteristic.uuid)")
            return
        }
        if characteristic === commandCharacteristic {
            guard data.count == 1 else {
                log("Unexpected CMD notification length: \(data.count)")
                return
            }
            log("CMD ACK: \(rawHex(data))")
            guard pendingStatus != nil, pendingKind == .command else {
                log("Unsolicited CMD ACK ignored")
                return
            }
            finishStatus(.success(OTAStatus(generalStatus: data[0], percent: 0)))
            return
        }
        if characteristic === statusCharacteristic {
            if data.count == 5,
               (try? OTAProtocol.decodeStatus(data)) == nil,
               otaUpdater?.phase == .erasing {
                do {
                    let eraseStatus = try OTAProtocol.decodeEraseStatus(data)
                    otaUpdater?.receiveEraseStatus(eraseStatus)
                } catch {
                    log("Invalid erase STATUS notification: \(error.localizedDescription)")
                }
                return
            }
            do {
                let status = try OTAProtocol.decodeStatus(data)
                log("STATUS: generalStatus=\(status.generalStatus), percent=\(status.percent)")
                guard pendingStatus != nil, pendingKind == .batch else {
                    if otaUpdater?.phase == .erasing {
                        otaUpdater?.receiveStatus(status)
                        return
                    }
                    log("Unsolicited STATUS notification ignored")
                    return
                }
                finishStatus(.success(status))
            } catch {
                log("Invalid STATUS notification: \(error.localizedDescription)")
            }
            return
        }

        if characteristic === serialCharacteristic {
            let value = displayValue(data)
            serialNumber = value.text
            serialNumberIsSuspect = value.isSuspect
        } else if characteristic === hardwareRevisionCharacteristic {
            let value = displayValue(data)
            hardwareRevision = value.text
            hardwareRevisionIsSuspect = value.isSuspect
        } else if characteristic.uuid == BLEConstants.bootloaderFwVer {
            let value = displayValue(data)
            fwVersion = value.text
            fwVersionIsSuspect = value.isSuspect
        } else if characteristic.uuid == BLEConstants.wirelessFwInfo {
            let value = displayValue(data)
            wirelessFwInfo = value.text
            wirelessFwInfoIsSuspect = value.isSuspect
        }
        log("Read \(characteristic.uuid): \(rawHex(data))")
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic === commandCharacteristic else { return }
        if let error {
            log("CMD write failed: \(error.localizedDescription)")
            finishWrite(.failure(error))
        } else {
            log("CMD write acknowledged by BLE")
            finishWrite(.success(()))
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        finishFlow(.success(()))
    }
}
