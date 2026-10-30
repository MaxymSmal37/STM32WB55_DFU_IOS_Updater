import Foundation

nonisolated enum CRC8 {
    static func checksum(
        of bytes: some Sequence<UInt8>,
        polynomial: UInt8 = BLEConstants.crcPolynomial,
        initialValue: UInt8 = BLEConstants.crcInitialValue
    ) -> UInt8 {
        var crc = initialValue
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 {
                crc = (crc & 0x80) != 0 ? (crc << 1) ^ polynomial : crc << 1
            }
        }
        return crc
    }
}
