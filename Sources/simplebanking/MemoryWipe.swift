import Foundation

// MARK: - Memory wipe utilities for sensitive byte buffers
//
// Swift `String` ist immutable + Copy-on-Write — echtes Memory-Wiping ist nicht
// möglich, ohne den ganzen UI-Input-Stack umzubauen (SecureField liefert auch
// nur einen `String` zurück, ARC kontrolliert Lifetime). Was wir aber zuverlässig
// können: abgeleitete Schlüssel-Bytes und entschlüsselte Plaintext-Buffer
// zeroizen, sobald sie nicht mehr gebraucht werden. Das reduziert das Window,
// in dem PBKDF2-Output oder dechiffrierte Bank-Credentials im Heap liegen.
//
// Verwendet `memset_s` (POSIX/Darwin) — der Compiler darf den Call NICHT
// wegoptimieren, im Gegensatz zu plain `memset` oder einer Schleife.

enum MemoryWipe {

    /// Überschreibt das übergebene Byte-Array mit Nullen.
    /// `memset_s` ist optimization-safe — der Compiler entfernt den Call nicht,
    /// auch wenn er ihn als "dead store" einstuft.
    static func zeroize(_ bytes: inout [UInt8]) {
        guard !bytes.isEmpty else { return }
        let count = bytes.count
        bytes.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            _ = memset_s(base, count, 0, count)
        }
    }

    /// Überschreibt die übergebene Data mit Nullen.
    static func zeroize(_ data: inout Data) {
        guard !data.isEmpty else { return }
        let count = data.count
        data.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else { return }
            _ = memset_s(base, count, 0, count)
        }
    }
}
