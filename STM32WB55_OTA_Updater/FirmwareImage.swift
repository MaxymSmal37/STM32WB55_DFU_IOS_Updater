import CryptoKit
import Foundation

nonisolated struct FirmwareImage: Sendable {
    let data: Data
    let size: UInt32
    let sha256: Data

    init(data: Data) throws {
        guard data.count <= Int(UInt32.max) else { throw OTAProtocolError.imageTooLarge }
        self.data = data
        self.size = UInt32(data.count)
        self.sha256 = Data(SHA256.hash(data: data))
    }

    func batches(size batchSize: Int) throws -> FirmwareBatchSequence {
        guard batchSize > 0,
              batchSize.isMultiple(of: BLEConstants.batchPayloadMin) else {
            throw OTAProtocolError.invalidBatchSize(batchSize)
        }
        return FirmwareBatchSequence(data: data, batchSize: batchSize)
    }
}

nonisolated struct FirmwareBatch: Sendable {
    let address: UInt32
    let payload: Data
    let firmwareBytesCount: Int
}

nonisolated struct FirmwareBatchSequence: Sequence, Sendable {
    struct Iterator: IteratorProtocol, Sendable {
        private let data: Data
        private let batchSize: Int
        private var firmwareOffset = 0
        private var address: UInt32 = 0

        fileprivate init(data: Data, batchSize: Int) {
            self.data = data
            self.batchSize = batchSize
        }

        mutating func next() -> FirmwareBatch? {
            guard firmwareOffset < data.count else { return nil }
            let count = Swift.min(batchSize, data.count - firmwareOffset)
            var payload = data.subdata(in: firmwareOffset..<(firmwareOffset + count))
            let paddedSize = ((count + BLEConstants.batchPayloadMin - 1)
                / BLEConstants.batchPayloadMin) * BLEConstants.batchPayloadMin
            payload.append(contentsOf: repeatElement(0xFF, count: paddedSize - count))
            let batch = FirmwareBatch(
                address: address,
                payload: payload,
                firmwareBytesCount: count
            )
            firmwareOffset += count
            address += UInt32(payload.count)
            return batch
        }
    }

    private let data: Data
    private let batchSize: Int

    fileprivate init(data: Data, batchSize: Int) {
        self.data = data
        self.batchSize = batchSize
    }

    func makeIterator() -> Iterator {
        Iterator(data: data, batchSize: batchSize)
    }
}
