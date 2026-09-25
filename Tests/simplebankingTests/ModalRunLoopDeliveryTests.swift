import XCTest
import AppKit
@testable import simplebanking

// MARK: - Zustellung auf den Main-Thread während einer modalen Sitzung
//
// Bei Banken mit Tipp-TAN (HypoVereinsbank) erschien das TAN-Feld erst, wenn der Nutzer
// die Einrichtung abbrach — gemessen 17 bis 60 Sekunden zu spät, die TAN war dann
// abgelaufen. Ursache war kein Z-Order-Problem, sondern die Zustellung: `NSApp.runModal`
// fährt die Runloop in `NSModalPanelRunLoopMode`, und ein `await MainActor.run` kam dort
// nicht rechtzeitig an — er blieb liegen, bis die modale Sitzung endete.
//
// Nachtrag 25.09.2026: Die frühere Erklärung „die Main-Dispatch-Queue wird im Modal-Mode
// gar nicht bedient" ist so nicht haltbar. Nachgemessen hängt das am Prozesszustand —
// ohne Fenster nicht bedient, mit Fenster bedient (s. den Test weiter unten). Was bleibt,
// ist der gemessene Befund aus dem Feld: Über `RunLoop.perform(inModes:)` kommt der Hop
// rechtzeitig an, über die Main-Queue kam er es nicht.
//
// Diese Tests pumpen die Runloop AUSSCHLIESSLICH im Modal-Mode — also so, wie sie
// während `NSApp.runModal` läuft — und prüfen, was dabei ankommt. Die bestehenden
// `SCAFieldInputTests` (reine Validierungslogik) können so etwas nicht sehen.

/// Thread-sicherer Briefkasten: geschrieben wird aus einem Task, gelesen vom Main-Thread,
/// der dabei die Runloop pumpt.
private final class Mailbox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
    func set(_ v: T) {
        lock.lock(); defer { lock.unlock() }
        stored = v
    }
}

final class ModalRunLoopDeliveryTests: XCTestCase {

    /// Pumpt die Runloop nur im Modal-Mode, bis `check` erfüllt ist oder die Zeit abläuft.
    private func pumpModalRunLoop(timeout: TimeInterval, until check: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if check() { return }
            RunLoop.main.run(mode: .modalPanel, before: Date().addingTimeInterval(0.02))
        }
    }

    /// Der Kern der Reparatur: `onMainRunLoop` kommt auch dann an, wenn nur der
    /// Modal-Mode bedient wird.
    func test_onMainRunLoop_wirdImModalPanelModeBedient() {
        let box = Mailbox<Int>()
        Task.detached {
            let value = await YaxiService.onMainRunLoop { 42 }
            box.set(value)
        }
        pumpModalRunLoop(timeout: 3) { box.value != nil }
        XCTAssertEqual(box.value, 42,
                       "Hop kam im Modal-Mode nicht an — genau der HVB-Fehler")
    }

    /// Die Gegenprobe — und sie fiel anders aus als lange angenommen.
    ///
    /// Hier stand bis 25.09.2026 die Behauptung, die Main-Queue werde im Modal-Mode
    /// **nie** bedient. Der Test bestand auch, aber nur, solange vor ihm kein Fenster
    /// entstanden war. Sobald eine andere Testklasse eines anlegte, kippte er. Beide
    /// Fälle im selben Prozess nachgemessen:
    ///
    ///     ohne Fenster im Prozess → Main-Queue NICHT bedient
    ///     mit einem Fenster       → Main-Queue bedient
    ///
    /// Das Anlegen eines `NSWindow` hängt die Quelle der Main-Queue also in den
    /// Modal-Mode ein. Ein echter App-Prozess hat immer Fenster — die Absolutaussage
    /// traf dort demnach nie zu, und der Test prüfte in Wahrheit nur, dass die
    /// Testumgebung noch keine AppKit-Fenster gesehen hatte.
    ///
    /// Geprüft wird deshalb jetzt die Hälfte, die reproduzierbar ist und die Lage im
    /// Programm beschreibt: mit Fenster wird bedient. Dass `onMainRunLoop` trotzdem
    /// gebraucht wird, sichert der Test darüber ab — der HVB-Fehler war real und
    /// gemessen, „bedient" heißt hier nur „irgendwann", nicht „rechtzeitig".
    func test_mainQueue_imModalMode_haengtAmVorhandenseinEinesFensters() {
        let fenster = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                               styleMask: [.titled], backing: .buffered, defer: false)
        // Ohne das gibt `close()` das Fenster frei, das ARC danach noch einmal freigibt
        // — der Testlauf endet mit SIGSEGV statt mit einem Ergebnis.
        fenster.isReleasedWhenClosed = false
        _ = fenster.contentView
        defer { fenster.close() }

        let box = Mailbox<Int>()
        DispatchQueue.main.async { box.set(1) }
        pumpModalRunLoop(timeout: 1.0) { box.value != nil }
        XCTAssertEqual(box.value, 1,
                       "Mit einem Fenster im Prozess wird die Main-Queue im Modal-Mode bedient. "
                       + "Kippt das, ist die Begründung an YaxiService.onMainRunLoop erneut zu prüfen.")
    }

    /// Nach dem Pumpen im Modal-Mode muss die Main-Queue wieder normal laufen, sonst
    /// hätte der Test die Umgebung für alle folgenden beschädigt.
    func test_mainQueue_laeuftNachDemModalModeWieder() {
        let box = Mailbox<Int>()
        DispatchQueue.main.async { box.set(7) }
        let deadline = Date().addingTimeInterval(2)
        while box.value == nil, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(box.value, 7)
    }

    // MARK: Genau-einmal-Wächter

    /// Der Presenter meldet genau einmal — aber die Zusage steht in einer anderen Datei,
    /// und ein zweites `resume` wäre ein Absturz statt eines Fehlverhaltens.
    func test_resumeGuard_verschlucktDenZweitenAufruf() async {
        let value = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            Task { @MainActor in
                let guard_ = FieldInputResumeGuard(cont)
                guard_.resume("123456")
                guard_.resume("999999")   // ohne Wächter: Absturz
                guard_.resume(nil)
            }
        }
        XCTAssertEqual(value, "123456")
    }

    func test_resumeGuard_reichtAuchNilDurch() async {
        let value = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            Task { @MainActor in
                let guard_ = FieldInputResumeGuard(cont)
                guard_.resume(nil)
                guard_.resume("zu spät")
            }
        }
        XCTAssertNil(value)
    }
}
