import XCTest
@testable import STM32WB55_OTA_Updater

@MainActor
final class OTAProtocolTests: XCTestCase {
    func testCRC8KnownVector() {
        XCTAssertEqual(CRC8.checksum(of: Array("123456789".utf8)), 0xF4)
        XCTAssertEqual(CRC8.checksum(of: []), 0x00)
    }

    func testCommandEncodingIncludesLengthPayloadAndCRC() throws {
        let frame = try OTAProtocol.setFirmwareSize(0x12345678)

        XCTAssertEqual(Array(frame.prefix(7)), [0xAA, 0x03, 0x04, 0x78, 0x56, 0x34, 0x12])
        XCTAssertEqual(frame.last, CRC8.checksum(of: frame.dropLast()))
    }

    func testSetFirmwareHashPartsEncodeEachHalf() throws {
        let hash = Data((0..<32).map(UInt8.init))

        let first = try OTAProtocol.setFirmwareHashPart(0, hash: hash)
        let second = try OTAProtocol.setFirmwareHashPart(1, hash: hash)

        XCTAssertEqual(first.count, 21)
        XCTAssertEqual(Array(first[3..<20]), [0] + Array(0..<16).map(UInt8.init))
        XCTAssertEqual(Array(second[3..<20]), [1] + Array(16..<32).map(UInt8.init))
        XCTAssertEqual(first.last, CRC8.checksum(of: first.dropLast()))
        XCTAssertEqual(second.last, CRC8.checksum(of: second.dropLast()))
    }

    func testSetFirmwareHashCanUseFourEightByteParts() throws {
        let hash = Data((0..<32).map(UInt8.init))

        let parts = try (0..<4).map {
            try OTAProtocol.setFirmwareHashPart($0, hash: hash, partSize: 8)
        }

        XCTAssertEqual(parts.count, 4)
        for (index, frame) in parts.enumerated() {
            XCTAssertEqual(frame.count, 13)
            XCTAssertEqual(frame[3], UInt8(index))
            XCTAssertEqual(Array(frame[4..<12]), Array((index * 8)..<(index * 8 + 8)).map(UInt8.init))
            XCTAssertEqual(frame.last, CRC8.checksum(of: frame.dropLast()))
        }
    }

    func testDataBatchEncoding() throws {
        let payload = Data(repeating: 0x5A, count: 8)
        let frame = try OTAProtocol.dataBatch(address: 0x12345678, payload: payload)

        XCTAssertEqual(frame.count, BLEConstants.dataFrameOverhead + payload.count)
        XCTAssertEqual(Array(frame.prefix(5)), [0x78, 0x56, 0x34, 0x12, 0x08])
        XCTAssertEqual(frame.last, CRC8.checksum(of: frame.dropLast()))
    }

    func testStatusDecodingValidFrame() throws {
        var frame = Data([BLEConstants.sof, 0, 0, 1])
        frame.append(CRC8.checksum(of: frame))

        let status = try OTAProtocol.decodeStatus(frame)
        XCTAssertTrue(status.isSuccess)
    }

    func testStatusDecodingRejectsBadCRCAndBadStartByte() throws {
        XCTAssertThrowsError(try OTAProtocol.decodeStatus(Data([0xAA, 0, 0, 1, 0xFF]))) { error in
            XCTAssertEqual(error as? OTAProtocolError, .invalidStatusCRC)
        }

        var badStart = Data([0, 0, 0, 1])
        badStart.append(CRC8.checksum(of: badStart))
        XCTAssertThrowsError(try OTAProtocol.decodeStatus(badStart)) { error in
            XCTAssertEqual(error as? OTAProtocolError, .invalidStatusStartOfFrame)
        }
    }

    func testFirmwareBatchesPadFinalPayloadAndMaintainAlignment() throws {
        let payloadSize = BLEConstants.maximumBatchPayloadSize
        let source = Data((0..<(payloadSize + 2)).map(UInt8.init))
        let image = try FirmwareImage(data: source)
        let batches = Array(try image.batches(size: payloadSize))

        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches[0].address, 0)
        XCTAssertEqual(batches[0].payload.count, payloadSize)
        XCTAssertEqual(batches[0].firmwareBytesCount, payloadSize)
        XCTAssertEqual(batches[1].address, UInt32(payloadSize))
        XCTAssertEqual(batches[1].firmwareBytesCount, 2)
        XCTAssertEqual(Array(batches[1].payload.prefix(2)), Array(source.suffix(2)))
        XCTAssertEqual(
            Array(batches[1].payload.dropFirst(2)),
            Array(repeating: 0xFF, count: payloadSize - 2)
        )
        XCTAssertEqual(batches[1].payload.count % 8, 0)
    }

    func testBatchSizeMustBeEightByteAligned() throws {
        let image = try FirmwareImage(data: Data([1]))
        XCTAssertThrowsError(try image.batches(size: 127))
    }

    func testUpdaterCompletesWithMockTransport() async {
        let transport = MockOTATransport()
        let updater = OTAUpdater(transport: transport)
        updater.selectFirmware(Data(repeating: 0xA5, count: 10))
        let isPrepared = await waitUntil { updater.selectedFirmware != nil }
        XCTAssertTrue(isPrepared)

        updater.start()
        let isComplete = await waitUntil { updater.phase == .done }
        XCTAssertTrue(isComplete)
        XCTAssertEqual(updater.bytesSent, 10)
        XCTAssertEqual(updater.progress, 1)
        XCTAssertFalse(transport.isReady)
    }

    func testUpdaterRetriesBatchOnNackAndTimeout() async {
        let transport = MockOTATransport()
        transport.responses = [
            .acknowledge, .acknowledge, .acknowledge, .acknowledge,
            .nack(0), .timeout, .nack(1), .acknowledge,
            .acknowledge
        ]
        let updater = OTAUpdater(transport: transport)
        updater.selectFirmware(Data(repeating: 0x5A, count: 8))
        let isPrepared = await waitUntil { updater.selectedFirmware != nil }
        XCTAssertTrue(isPrepared)

        updater.start()
        let isComplete = await waitUntil { updater.phase == .done }
        XCTAssertTrue(isComplete)
        XCTAssertEqual(transport.writtenFrames.count, 9)
        XCTAssertEqual(updater.bytesSent, 8)
    }

    func testUpdaterSurfacesMockDisconnect() async {
        let transport = MockOTATransport()
        transport.responses = [.disconnect]
        let updater = OTAUpdater(transport: transport)
        updater.selectFirmware(Data([1, 2, 3]))
        let isPrepared = await waitUntil { updater.selectedFirmware != nil }
        XCTAssertTrue(isPrepared)

        updater.start()
        let didFail = await waitUntil {
            if case .failed = updater.phase { return true }
            return false
        }
        XCTAssertTrue(didFail)
        XCTAssertEqual(updater.phase, .failed("Connection lost"))
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
