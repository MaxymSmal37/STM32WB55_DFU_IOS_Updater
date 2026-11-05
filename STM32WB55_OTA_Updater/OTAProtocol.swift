import Foundation

nonisolated enum OTACommand: UInt8 {
    case startErase = 0
    case startUpdate = 1
    case stopUpdate = 2
    case getStatus = 3
    case setFirmwareSize = 4
    case setFirmwareHash = 5
}

nonisolated struct OTAStatus: Equatable, Sendable {
    let generalStatus: UInt8
    let percent: UInt8                      // 0...100, computed by the MCU

    var progress: Double { Double(min(percent, 100)) / 100.0 }
}

nonisolated struct OTAEraseStatus: Equatable, Sendable {
    let generalStatus: UInt8
    let currentPageNumber: UInt32

    var progress: Double {
        min(Double(currentPageNumber) / Double(BLEConstants.flashPageCount), 1)
    }
}

nonisolated enum OTAProtocolError: Error, LocalizedError, Equatable {
    case invalidStatusLength(Int)
    case invalidEraseStatusLength(Int)
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
        case .invalidEraseStatusLength(let length): "Invalid erase status length: \(length)"
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
        guard frame.count == 4 else {
            throw OTAProtocolError.invalidStatusLength(frame.count)
        }
        guard frame[0] == BLEConstants.sof else {
            throw OTAProtocolError.invalidStatusStartOfFrame
        }
        guard CRC8.checksum(of: frame.prefix(3)) == frame[3] else {
            throw OTAProtocolError.invalidStatusCRC
        }
        return OTAStatus(generalStatus: frame[1], percent: frame[2])
    }
    
    static func decodeEraseStatus(_ data: Data) throws -> OTAEraseStatus {
        guard data.count == 5 else {
            throw OTAProtocolError.invalidEraseStatusLength(data.count)
        }
        let currentPageNumber = data[1...4].enumerated().reduce(UInt32(0)) {
            $0 | (UInt32($1.element) << (8 * $1.offset))
        }
        return OTAEraseStatus(generalStatus: data[0], currentPageNumber: currentPageNumber)
    }
}
