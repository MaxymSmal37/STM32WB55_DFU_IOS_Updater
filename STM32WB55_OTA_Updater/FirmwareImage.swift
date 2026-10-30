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
        guard batchSize > 0, batchSize.isMultiple(of: 8) else {
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
        private var offset = 0

        fileprivate init(data: Data, batchSize: Int) {
            self.data = data
            self.batchSize = batchSize
        }

        mutating func next() -> FirmwareBatch? {
            guard offset < data.count else { return nil }
            let count = Swift.min(batchSize, data.count - offset)
            var payload = data.subdata(in: offset..<(offset + count))
            payload.append(contentsOf: repeatElement(0xFF, count: batchSize - count))
            defer { offset += count }
            return FirmwareBatch(address: UInt32(offset), payload: payload, firmwareBytesCount: count)
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
