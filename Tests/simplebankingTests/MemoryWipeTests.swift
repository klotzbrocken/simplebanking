import XCTest
@testable import simplebanking

// MARK: - MemoryWipe tests
//
// Zweck: sicherstellen, dass `memset_s` die Bytes wirklich auf 0 setzt — und
// dass der Compiler unsere Wipes nicht wegoptimiert. Wenn ein zukünftiger
// Refactor plain `memset` oder eine for-Schleife einsetzt, würden diese
// Tests trotzdem grün bleiben — aber eine memory-inspection-Profile-Run
// würde den Unterschied zeigen. Hier prüfen wir das funktionale Outcome.

final class MemoryWipeTests: XCTestCase {

    // MARK: - [UInt8]

    func test_zeroize_uint8Array_overwritesAllBytes() {
        var bytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE]
        MemoryWipe.zeroize(&bytes)
        XCTAssertEqual(bytes, [0, 0, 0, 0, 0, 0, 0, 0])
    }

    func test_zeroize_uint8Array_keepsLength() {
        var bytes = [UInt8](repeating: 0xFF, count: 256)
        MemoryWipe.zeroize(&bytes)
        XCTAssertEqual(bytes.count, 256)
        XCTAssertTrue(bytes.allSatisfy { $0 == 0 })
    }

    func test_zeroize_emptyArray_isNoop() {
        var bytes: [UInt8] = []
        MemoryWipe.zeroize(&bytes)
        XCTAssertTrue(bytes.isEmpty)
    }

    // MARK: - Data

    func test_zeroize_data_overwritesAllBytes() {
        var data = Data([0x01, 0x02, 0x03, 0x04, 0xAB, 0xCD])
        MemoryWipe.zeroize(&data)
        XCTAssertEqual(data, Data([0, 0, 0, 0, 0, 0]))
    }

    func test_zeroize_data_keepsLength() {
        var data = Data(repeating: 0x42, count: 1024)
        MemoryWipe.zeroize(&data)
        XCTAssertEqual(data.count, 1024)
        XCTAssertTrue(data.allSatisfy { $0 == 0 })
    }

    func test_zeroize_emptyData_isNoop() {
        var data = Data()
        MemoryWipe.zeroize(&data)
        XCTAssertEqual(data.count, 0)
    }

    // MARK: - Realistisches Szenario

    func test_zeroize_pbkdf2OutputSize_works() {
        // 32 Bytes = SHA256 / AES-256 Schlüssellänge
        var key = [UInt8](repeating: 0xAA, count: 32)
        MemoryWipe.zeroize(&key)
        XCTAssertEqual(key, [UInt8](repeating: 0, count: 32))
    }
}
