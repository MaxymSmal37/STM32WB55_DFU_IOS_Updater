import CoreBluetooth
import Foundation

nonisolated enum BLEConstants {
    static let companyID: [UInt8] = [0x23, 0x23]
    static let manufacturerMarker: [UInt8] = [0x4D, 0x58]
    static let deviceType: UInt8 = 0x01

    static func uuid(_ short: UInt16) -> CBUUID {
        CBUUID(string: String(format: "0000%04X-8E22-4541-9D4C-21EDAE82ED19", short))
    }

    static let sysInfoService = uuid(0x1802)
    static let transferService = uuid(0xA001)

    static let bootloaderFwVer = uuid(0x2A25)
    static let wirelessFwInfo = uuid(0x2A28)
    static let serialNumber = uuid(0xAB03)
    static let hardwareRevision = uuid(0xAB04)

    static let cmd = uuid(0xAC01)
    static let data = uuid(0xAC02)
    static let status = uuid(0xAC03)

    static let sof: UInt8 = 0xAA
    static let crcPolynomial: UInt8 = 0x07
    static let crcInitialValue: UInt8 = 0x00
    static let maximumBatchPayloadSize = 128
    static let dataFrameOverhead = 6
    static let hashPartSize = 16 // Firmware-dependent: use 8 if CMD accepts at most 16 bytes.

    static let statusTimeout: TimeInterval = 5
    static let eraseTimeout: TimeInterval = 30
    static let writeTimeout: TimeInterval = 10
    static let maximumBatchRetries = 3
}
