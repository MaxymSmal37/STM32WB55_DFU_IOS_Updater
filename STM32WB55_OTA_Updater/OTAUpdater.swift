import Combine
import Foundation
import UIKit

enum OTAUpdatePhase: Equatable {
    case idle
    case preparing
    case erasing
    case uploading
    case verifying
    case done
    case failed(String)
    case cancelled

    var title: String {
        switch self {
        case .idle: "Ready"
        case .preparing: "Preparing…"
        case .erasing: "Erasing…"
        case .uploading: "Uploading…"
        case .verifying: "Verifying…"
        case .done: "Update complete, device will restart"
        case .failed(let reason): "Failed: \(reason)"
        case .cancelled: "Cancelled"
        }
    }

    var isActive: Bool {
        switch self {
        case .preparing, .erasing, .uploading, .verifying: true
        default: false
        }
    }
}

enum OTAOperationError: Error, LocalizedError {
    case timeout
    case connectionLost
    case notReady
    case frameLargerThanLinkLimit
    case insufficientWriteLength(required: Int, available: Int)
    case deviceRejected(String)

    var errorDescription: String? {
        switch self {
        case .timeout: "Timed out waiting for the device"
        case .connectionLost: "Connection lost"
        case .notReady: "Device is not ready for firmware updates"
        case .frameLargerThanLinkLimit: "Frame larger than link limit"
        case .insufficientWriteLength(let required, let available):
            "BLE write limit is \(available) bytes; \(required) bytes are required"
        case .deviceRejected(let reason): reason
        }
    }
}

@MainActor
protocol OTATransport: AnyObject {
    var isReady: Bool { get }
    var batchPayloadSize: Int? { get }
    var maxWriteNoResp: Int? { get }
    var maxWriteWithResp: Int? { get }

    func refreshLinkParameters()
    func sendCommandAndWaitForStatus(_ frame: Data, timeout: TimeInterval) async throws -> OTAStatus
    func sendBatchAndWaitForStatus(_ frame: Data, timeout: TimeInterval) async throws -> OTAStatus
    func disconnect()
}

@MainActor
final class OTAUpdater: ObservableObject {
    @Published private(set) var phase: OTAUpdatePhase = .idle
    @Published private(set) var progress = 0.0
    @Published private(set) var bytesSent = 0
    @Published private(set) var speedBytesPerSec = 0.0
    @Published private(set) var eta: TimeInterval?
    @Published private(set) var log: [String] = []
    @Published private(set) var selectedFirmware: FirmwareImage?
    @Published private(set) var firmwareLoadError: String?

    private let transport: OTATransport
    private var updateTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var selectionID = UUID()
    private var connectionWasLost = false
    private var requestedBatchPayloadSize: Int?
    private var requiresFullBatch = false

    init(transport: OTATransport) {
        self.transport = transport
    }

    var isUpdating: Bool { phase.isActive }
    var totalBytes: Int { selectedFirmware.map { Int($0.size) } ?? 0 }

    func selectFirmware(_ data: Data) {
        selectionTask?.cancel()
        let currentID = UUID()
        selectionID = currentID
        firmwareLoadError = nil
        selectedFirmware = nil
        selectionTask = Task { [weak self] in
            do {
                let image = try await Task.detached(priority: .userInitiated) {
                    try FirmwareImage(data: data)
                }.value
                guard let self, self.selectionID == currentID else { return }
                self.selectedFirmware = image
            } catch {
                guard let self, self.selectionID == currentID else { return }
                self.firmwareLoadError = error.localizedDescription
            }
        }
    }

    func start(batchPayloadSize: Int? = nil, requireFullBatch: Bool = false) {
        guard !isUpdating, selectedFirmware != nil else { return }
        connectionWasLost = false
        requestedBatchPayloadSize = batchPayloadSize
        requiresFullBatch = requireFullBatch
        updateTask?.cancel()
        updateTask = Task { [weak self] in await self?.runUpdate() }
    }

    func cancel() {
        guard isUpdating else { return }
        updateTask?.cancel()
        phase = .cancelled
        appendLog("Update cancelled")
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func connectionLost() {
        guard isUpdating else { return }
        connectionWasLost = true
        updateTask?.cancel()
        phase = .failed("Connection lost")
        appendLog("Connection lost; reconnect and retry from the beginning")
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func clearLog() {
        log.removeAll()
    }

    func clearFirmwareLoadError() {
        firmwareLoadError = nil
    }

    private func runUpdate() async {
        guard let image = selectedFirmware else { return }
        transport.refreshLinkParameters()
        guard transport.isReady else {
            phase = .failed(OTAOperationError.notReady.localizedDescription)
            appendLog("Update could not start: device is not ready")
            return
        }

        phase = .preparing
        progress = 0
        bytesSent = 0
        speedBytesPerSec = 0
        eta = nil
        appendLog("Preparing \(image.size)-byte firmware image")
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        do {
            guard let maxBatchPayloadSize = transport.batchPayloadSize,
                  let maxWriteNoResp = transport.maxWriteNoResp else {
                throw OTAOperationError.notReady
            }
            if requiresFullBatch && maxBatchPayloadSize < BLEConstants.batchPayloadTarget {
                throw OTAOperationError.deviceRejected("Waiting for 128-byte link")
            }
            let batchPayloadSize = requestedBatchPayloadSize.map {
                min($0, maxBatchPayloadSize)
            } ?? maxBatchPayloadSize
            guard batchPayloadSize >= BLEConstants.batchPayloadMin,
                  batchPayloadSize.isMultiple(of: BLEConstants.batchPayloadMin) else {
                throw OTAProtocolError.invalidBatchSize(batchPayloadSize)
            }
            let frameSize = batchPayloadSize + BLEConstants.batchOverhead
            appendLog(
                "Batch payload \(batchPayloadSize) B (maxWriteNoResp \(maxWriteNoResp), frame \(frameSize) B)"
            )

//            try await sendCommand(OTAProtocol.setFirmwareSize(image.size), label: "Set firmware size")
//            let commandWriteLimit = min(
//                transport.maxWriteWithResp ?? 0,
//                BLEConstants.cmdCharacteristicLength
//            )
//            let hashPartSize = commandWriteLimit >= BLEConstants.hashPartSize + 5
//                ? BLEConstants.hashPartSize
//                : BLEConstants.fallbackHashPartSize
//            let hashPartCount = (image.sha256.count + hashPartSize - 1) / hashPartSize
//            for part in 0..<hashPartCount {
//                try await sendCommand(
//                    OTAProtocol.setFirmwareHashPart(
//                        part,
//                        hash: image.sha256,
//                        partSize: hashPartSize
//                    ),
//                    label: "Set firmware hash part \(part + 1)"
//                )
//            }

            phase = .erasing
            try await sendCommand(
                OTAProtocol.command(.startUpdate),
                label: "Start update",
                timeout: BLEConstants.eraseTimeout
            )

            phase = .uploading
            let transferStart = Date()
            for batch in try image.batches(size: batchPayloadSize) {
                try Task.checkCancellation()
                let frame = try OTAProtocol.dataBatch(address: batch.address, payload: batch.payload)
                guard frame.count <= maxWriteNoResp,
                      frame.count <= BLEConstants.dataCharacteristicLength else {
                    throw OTAOperationError.frameLargerThanLinkLimit
                }
                try await sendBatchWithRetry(frame)
                bytesSent += batch.firmwareBytesCount
                progress = image.size == 0 ? 1 : Double(bytesSent) / Double(image.size)
                let elapsed = max(Date().timeIntervalSince(transferStart), 0.001)
                speedBytesPerSec = Double(bytesSent) / elapsed
                let remaining = max(Int(image.size) - bytesSent, 0)
                eta = speedBytesPerSec > 0 ? Double(remaining) / speedBytesPerSec : nil
            }

            phase = .verifying
            try await sendCommand(
                OTAProtocol.command(.stopUpdate),
                label: "Stop update and verify",
                timeout: BLEConstants.eraseTimeout
            )
            progress = 1
            phase = .done
            appendLog("Update complete; device will restart")
            transport.disconnect()
        } catch is CancellationError {
            if !connectionWasLost, phase.isActive {
                phase = .cancelled
                appendLog("Update cancelled")
            }
        } catch {
            guard !connectionWasLost else { return }
            phase = .failed(error.localizedDescription)
            appendLog("Update failed: \(error.localizedDescription)")
        }
    }

    private func sendCommand(
        _ frame: Data,
        label: String,
        timeout: TimeInterval = 5
    ) async throws {
        let availableLength = min(
            transport.maxWriteWithResp ?? 0,
            BLEConstants.cmdCharacteristicLength
        )
        guard frame.count <= availableLength else {
            throw OTAOperationError.insufficientWriteLength(
                required: frame.count,
                available: availableLength
            )
        }
        appendLog("\(label)…")
        let status = try await transport.sendCommandAndWaitForStatus(frame, timeout: timeout)
        try validate(status)
        appendLog("\(label): acknowledged")
    }

    private func sendBatchWithRetry(_ frame: Data) async throws {
        for retry in 0...BLEConstants.maximumBatchRetries {
            do {
                let status = try await transport.sendBatchAndWaitForStatus(
                    frame,
                    timeout: BLEConstants.statusTimeout
                )
                try validate(status)
                return
            } catch {
                guard retry < BLEConstants.maximumBatchRetries, isRetryable(error) else {
                    throw error
                }
                appendLog("Batch retry \(retry + 1)/\(BLEConstants.maximumBatchRetries): \(error.localizedDescription)")
            }
        }
    }

    private func validate(_ status: OTAStatus) throws {
        guard status.isSuccess else {
            throw OTAOperationError.deviceRejected(status.failureDescription)
        }
    }

    private func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if case OTAOperationError.connectionLost = error { return false }
        if case OTAOperationError.notReady = error { return false }
        return true
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        log.append("[\(formatter.string(from: Date()))] \(message)")
    }
}

@MainActor
final class MockOTATransport: OTATransport {
    enum Response {
        case acknowledge
        case nack(UInt16)
        case timeout
        case disconnect
    }

    var isReady = true
    var batchPayloadSize: Int? = BLEConstants.batchPayloadTarget
    var maxWriteNoResp: Int? = BLEConstants.dataCharacteristicLength
    var maxWriteWithResp: Int? = BLEConstants.cmdCharacteristicLength
    var responses: [Response] = []
    private(set) var writtenFrames: [Data] = []

    func refreshLinkParameters() {
        guard let maxWriteNoResp else {
            batchPayloadSize = nil
            return
        }
        batchPayloadSize = STM32WB55_OTA_Updater.batchPayloadSize(
            maxWriteNoResp: maxWriteNoResp
        )
    }

    func sendCommandAndWaitForStatus(_ frame: Data, timeout: TimeInterval) async throws -> OTAStatus {
        let availableLength = min(
            maxWriteWithResp ?? 0,
            BLEConstants.cmdCharacteristicLength
        )
        guard frame.count <= availableLength else {
            throw OTAOperationError.insufficientWriteLength(
                required: frame.count,
                available: availableLength
            )
        }
        return try await respond(to: frame)
    }

    func sendBatchAndWaitForStatus(_ frame: Data, timeout: TimeInterval) async throws -> OTAStatus {
        guard let maxWriteNoResp,
              frame.count <= maxWriteNoResp,
              frame.count <= BLEConstants.dataCharacteristicLength else {
            throw OTAOperationError.frameLargerThanLinkLimit
        }
        return try await respond(to: frame)
    }

    func disconnect() {
        isReady = false
    }

    private func respond(to frame: Data) async throws -> OTAStatus {
        guard isReady else { throw OTAOperationError.connectionLost }
        writtenFrames.append(frame)
        let response = responses.isEmpty ? .acknowledge : responses.removeFirst()
        switch response {
        case .acknowledge:
            return OTAStatus(errorCode: 0, acknowledgement: 1)
        case .nack(let code):
            return OTAStatus(errorCode: code, acknowledgement: 0)
        case .timeout:
            throw OTAOperationError.timeout
        case .disconnect:
            isReady = false
            throw OTAOperationError.connectionLost
        }
    }
}
