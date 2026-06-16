import AppKit
import SwiftUI

// MARK: - View

/// „Kiste der Einkäufe" — Liste aller REWE-Bons eines Slots, jede Zeile
/// aufklappbar zum Warenkorb. Liest lokal aus `ReweReceiptStore` (kein
/// Master-Passwort-/Bank-Gate). Ersetzt beim aktiven REWE-Slot das Bank-
/// Umsatzfenster.
struct REWEReceiptsView: View {
    let slotId: String
    @State private var receipts: [ReweReceipt] = []
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Kiste der Einkäufe").font(.headline)
                Spacer()
                Text("\(receipts.count) Einkäufe").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()

            if receipts.isEmpty {
                VStack(spacing: 6) {
                    Text("Noch keine Bons.").foregroundStyle(.secondary)
                    Text("Im REWE-Fenster synchronisieren.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(receipts) { r in
                            row(r)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 460)
        .onAppear { receipts = (try? ReweReceiptStore.all(slotId: slotId)) ?? [] }
    }

    @ViewBuilder
    private func row(_ r: ReweReceipt) -> some View {
        let isOpen = expanded.contains(r.receiptId)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if isOpen { expanded.remove(r.receiptId) } else { expanded.insert(r.receiptId) }
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dateString(r.timestamp)).font(.system(size: 13, weight: .semibold))
                        Text("\(r.marketCity ?? r.marketName ?? "REWE") · \(r.items.count) Artikel")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(euro(r.totalCents)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(alignment: .leading, spacing: 3) {
                    if r.items.isEmpty {
                        Text("Kein Warenkorb (Bon nicht geparst).")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(r.items.enumerated()), id: \.offset) { _, it in
                            HStack(spacing: 8) {
                                Text(it.name).font(.caption)
                                if let q = it.quantity {
                                    Text(q).font(.caption2).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Text(euro(it.totalCents)).font(.caption).monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.leading, 8).padding(.bottom, 2)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func euro(_ c: Int) -> String { String(format: "%.2f €", Double(c) / 100) }
    private func dateString(_ iso: String) -> String {
        let p = String(iso.prefix(10)).split(separator: "-")
        return p.count == 3 ? "\(p[2]).\(p[1]).\(p[0])" : String(iso.prefix(10))
    }
}

// MARK: - Window

@MainActor
final class REWEReceiptsWindow: NSObject, NSWindowDelegate {
    private static var retained: REWEReceiptsWindow?
    private var window: NSWindow!

    static func present(slotId: String) {
        if let r = retained {
            r.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let c = REWEReceiptsWindow()
        retained = c
        c.show(slotId: slotId)
    }

    private func show(slotId: String) {
        let host = NSHostingController(rootView: REWEReceiptsView(slotId: slotId))
        window = NSWindow(contentViewController: host)
        window.title = "REWE — Kiste der Einkäufe"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 460, height: 580))
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { Self.retained = nil }
}
