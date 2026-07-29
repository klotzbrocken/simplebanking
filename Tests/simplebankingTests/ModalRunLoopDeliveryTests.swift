import XCTest
import AppKit
@testable import simplebanking

// MARK: - Zustellung auf den Main-Thread während einer modalen Sitzung
//
// Bei Banken mit Tipp-TAN (HypoVereinsbank) erschien das TAN-Feld erst, wenn der Nutzer
// die Einrichtung abbrach — gemessen 17 bis 60 Sekunden zu spät, die TAN war dann
// abgelaufen. Ursache war kein Z-Order-Problem, sondern die Zustellung: `NSApp.runModal`
// fährt die Runloop in `NSModalPanelRunLoopMode`, und die Main-Dispatch-Queue wird dort
// nicht bedient. Jeder `await MainActor.run` blieb deshalb liegen, bis die modale
// Sitzung endete.
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

    /// Die Gegenprobe, die erklärt, warum es der alte Weg nicht konnte. Schlägt dieser
    /// Test eines Tages um (weil AppKit den Modal-Mode zu den Common-Modes nimmt), ist
    /// das keine Verschlechterung — aber dann ist die Begründung an `onMainRunLoop`
    /// überholt und gehört korrigiert.
    func test_mainQueue_wirdImModalPanelModeNichtBedient() {
        let box = Mailbox<Int>()
        DispatchQueue.main.async { box.set(1) }
        pumpModalRunLoop(timeout: 0.5) { box.value != nil }
        XCTAssertNil(box.value,
                     "Main-Queue wurde im Modal-Mode bedient — dann ist die Begründung " +
                     "an YaxiService.onMainRunLoop überholt")
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
