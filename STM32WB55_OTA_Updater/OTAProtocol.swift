import Foundation

nonisolated enum OTACommand: UInt8 {
    case startUpdate = 0
    case stopUpdate = 1
    case getStatus = 2
    case setFirmwareSize = 3
    case setFirmwareHash = 4
}

nonisolated struct OTAStatus: Equatable, Sendable {
    let errorCode: UInt16
    let acknowledgement: UInt8

    var isSuccess: Bool { errorCode == 0 && acknowledgement == 1 }

    var failureDescription: String {
        switch errorCode {
        case 0: "CRC failed"
        case 1: "Hash set failed"
        default: "Device error \(errorCode)"
        }
    }
}

nonisolated enum OTAProtocolError: Error, LocalizedError, Equatable {
    case invalidStatusLength(Int)
    case invalidStatusStartOfFrame
    case invalidStatusCRC
    case payloadTooLarge(Int)
    case invalidHashPart(Int)
    case invalidBatchSize(Int)
    case imageTooLarge
    case deviceRejected(String)

    var errorDescription: String? {
        switch self {
        case .invalidStatusLength(let length): "Invalid status frame length: \(length)"
        case .invalidStatusStartOfFrame: "Invalid status start byte"
        case .invalidStatusCRC: "Status CRC check failed"
        case .payloadTooLarge(let length): "Command payload is too large: \(length) bytes"
        case .invalidHashPart(let part): "Invalid firmware hash part: \(part)"
        case .invalidBatchSize(let size): "Batch size must be a positive multiple of 8 (got \(size))"
        case .imageTooLarge: "Firmware image is too large for the protocol"
        case .deviceRejected(let reason): reason
        }
    }
}

nonisolated enum OTAProtocol {
    static func command(_ command: OTACommand, payload: Data = Data()) throws -> Data {
        guard payload.count <= Int(UInt8.max) else {
            throw OTAProtocolError.payloadTooLarge(payload.count)
        }
        var frame = Data([BLEConstants.sof, command.rawValue, UInt8(payload.count)])
        frame.append(payload)
        frame.append(CRC8.checksum(of: frame))
        
        return frame
    }

    static func setFirmwareSize(_ size: UInt32) throws -> Data {
        let payload = Data((0..<4).map { UInt8(truncatingIfNeeded: size >> (8 * $0)) })
        return try command(.setFirmwareSize, payload: payload)
    }

    static func setFirmwareHashPart(
        _ part: Int,
        hash: Data,
        partSize: Int = BLEConstants.hashPartSize
    ) throws -> Data {
        guard partSize > 0 else {
            throw OTAProtocolError.invalidHashPart(part)
        }
        let partCount = (hash.count + partSize - 1) / partSize
        guard hash.count == 32, (0..<partCount).contains(part) else {
            throw OTAProtocolError.invalidHashPart(part)
        }
        let start = part * partSize
        let end = min(start + partSize, hash.count)
        var payload = Data([UInt8(part)])
        payload.append(hash.subdata(in: start..<end))
        return try command(.setFirmwareHash, payload: payload)
    }

    static func dataBatch(address: UInt32, payload: Data) throws -> Data {
        guard payload.count > 0,
              payload.count.isMultiple(of: BLEConstants.batchPayloadMin),
              payload.count <= Int(UInt8.max) else {
            throw OTAProtocolError.invalidBatchSize(payload.count)
        }
        var frame = Data((0..<4).map { UInt8(truncatingIfNeeded: address >> (8 * $0)) })
        frame.append(UInt8(payload.count))
        frame.append(payload)
        frame.append(CRC8.checksum(of: frame))
        return frame
    }

    static func decodeStatus(_ frame: Data) throws -> OTAStatus {
        guard frame.count == 5 else {
            throw OTAProtocolError.invalidStatusLength(frame.count)
        }
        guard frame[0] == BLEConstants.sof else {
            throw OTAProtocolError.invalidStatusStartOfFrame
        }
        guard CRC8.checksum(of: frame.prefix(4)) == frame[4] else {
            throw OTAProtocolError.invalidStatusCRC
        }
        let errorCode = UInt16(frame[1]) | (UInt16(frame[2]) << 8)
        return OTAStatus(errorCode: errorCode, acknowledgement: frame[3])
    }
}
