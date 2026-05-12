import AppKit
import Foundation
import SwiftUI

// MARK: - TransferEmailService
//
// Generiert eine PDF-„Postkarte" zum erfolgreich abgesendeten Transfer
// und öffnet ein Compose-Fenster (Mail.app o.ä.) mit Empfänger, Betreff,
// Body-Text und PDF im Anhang. Der User reviewed + sendet aus dem
// eigenen Mail-Client — wir senden nichts ohne explizite Bestätigung.
//
// PDF-Format: 6×4" Querformat (postcard), 432×288 pt bei 72 dpi.

@MainActor
enum TransferEmailService {

    /// Eingabedaten für eine Quittung. Direkt aus dem TransferSheet befüllt.
    struct Receipt {
        let amountEUR: Decimal
        let recipientName: String
        let recipientIban: String
        let purpose: String?
        let scheduledDate: Date?           // nil = sofort
        let senderBankName: String         // z.B. „Sparkasse Frankfurt"
        let senderSlotNickname: String?
        let recipientBankName: String?     // resolved via BankLogoAssets / previewBank
        let executedAt: Date               // Zeitpunkt der erfolgreichen Bestätigung
    }

    /// Schreibt die PDF in ein temporäres File und liefert die URL zurück.
    /// Falls Rendering fehlschlägt, nil.
    static func writePDFReceipt(_ receipt: Receipt) -> URL? {
        let view = ReceiptCard(receipt: receipt)
            .frame(width: 432, height: 288)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = .init(width: 432, height: 288)
        renderer.scale = 2.0  // Retina

        let dir = FileManager.default.temporaryDirectory
        let name = "simplebanking-receipt-\(Int(receipt.executedAt.timeIntervalSince1970)).pdf"
        let url = dir.appendingPathComponent(name)

        var success = false
        renderer.render { _, ctx in
            var box = CGRect(x: 0, y: 0, width: 432, height: 288)
            guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            pdf.beginPDFPage(nil)
            ctx(pdf)
            pdf.endPDFPage()
            pdf.closePDF()
            success = true
        }
        return success ? url : nil
    }

    /// Öffnet das Compose-Fenster des System-Mail-Clients mit vorbereiteten
    /// Daten + PDF-Anhang. Wenn der User keinen Mail-Client konfiguriert
    /// hat, fällt das Service-Lookup nil zurück → silent skip.
    static func composeReceiptEmail(
        to recipientEmail: String,
        recipientName: String,
        amountEUR: Decimal,
        pdfURL: URL,
        senderSlotNickname: String?
    ) -> Bool {
        guard let service = NSSharingService(named: .composeEmail) else {
            AppLogger.log("TransferEmailService: no .composeEmail service available", category: "Transfer", level: "WARN")
            return false
        }
        service.recipients = [recipientEmail]
        service.subject = subject(for: recipientName, amountEUR: amountEUR)

        let body = bodyText(
            recipientName: recipientName,
            amountEUR: amountEUR,
            senderSlotNickname: senderSlotNickname
        )

        let canPerform = service.canPerform(withItems: [body, pdfURL])
        guard canPerform else {
            AppLogger.log("TransferEmailService: composeEmail can't perform — Mail.app fehlt?", category: "Transfer", level: "WARN")
            return false
        }
        service.perform(withItems: [body, pdfURL])
        return true
    }

    private static func subject(for recipientName: String, amountEUR: Decimal) -> String {
        let amountStr = formatEUR(amountEUR)
        let trimmedName = recipientName.trimmingCharacters(in: .whitespaces)
        if trimmedName.isEmpty {
            return L10n.t(
                "Überweisung über € \(amountStr) ist raus",
                "I just sent you € \(amountStr)"
            )
        }
        return L10n.t(
            "Überweisung über € \(amountStr) ist raus",
            "I just sent you € \(amountStr)"
        )
    }

    private static func bodyText(
        recipientName: String,
        amountEUR: Decimal,
        senderSlotNickname: String?
    ) -> String {
        let amountStr = formatEUR(amountEUR)
        let firstName = recipientName
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " ")
            .first ?? recipientName
        let from = senderSlotNickname?.nilIfEmpty.map { " (von \($0))" } ?? ""

        return L10n.t(
            """
            Hallo \(firstName),

            kurze Info: Ich habe dir gerade € \(amountStr) überwiesen\(from). \
            Der Auftrag ist bei meiner Bank rausgegangen — die genauen Details \
            findest du im PDF im Anhang.

            Die Überweisung ist auf dem Weg, sollte je nach Bank in Sekunden \
            bis wenigen Stunden bei dir ankommen.

            Liebe Grüße
            """,
            """
            Hi \(firstName),

            quick heads-up: I just sent you € \(amountStr). \
            The transfer is on its way — full details are in the PDF attached.

            Depending on the banks, it should land in your account within \
            seconds to a few hours.

            Cheers
            """
        )
    }

    private static func formatEUR(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: AppLanguage.resolved() == .de ? "de_DE" : "en_US")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }
}

// MARK: - ReceiptCard (PDF-Layout, postcard 6×4")

private struct ReceiptCard: View {
    let receipt: TransferEmailService.Receipt

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Hintergrund
            Color.white

            // Akzent-Streifen oben
            Rectangle()
                .fill(Color(red: 0.10, green: 0.46, blue: 0.82))
                .frame(height: 6)
                .frame(maxWidth: .infinity, alignment: .top)

            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    HStack(spacing: 8) {
                        appIconView
                        Text("simplebanking")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.black.opacity(0.85))
                    }
                    Spacer()
                }
                .padding(.top, 14)

                Spacer().frame(height: 14)

                // Hero
                Text("Überweisung gesendet")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.black.opacity(0.55))
                Text("€ \(formatEUR(receipt.amountEUR))")
                    .font(.system(size: 30, weight: .bold).monospacedDigit())
                    .foregroundColor(.black)
                    .padding(.top, 1)
                Text("an \(receipt.recipientName)")
                    .font(.system(size: 12))
                    .foregroundColor(.black.opacity(0.7))
                    .padding(.top, 2)

                Spacer().frame(height: 12)

                Divider()
                    .background(Color.black.opacity(0.10))

                // Detail-Tabelle
                VStack(spacing: 4) {
                    detailRow(label: "Empfänger", value: recipientLabel)
                    detailRow(label: "IBAN", value: shortIban(receipt.recipientIban),
                              uppercaseLabel: true)
                    if let purpose = receipt.purpose?.nilIfEmpty {
                        detailRow(label: "Verwendungszweck", value: purpose)
                    }
                    detailRow(label: "Absender", value: senderLabel)
                    detailRow(label: "Datum", value: formatDate(datumValue))
                }
                .padding(.top, 8)

                Spacer()

                // Footer + Disclaimer
                Text(disclaimerText)
                    .font(.system(size: 7.5))
                    .foregroundColor(.black.opacity(0.5))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 4) {
                    Spacer()
                    Text("simplebanking.de")
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundColor(Color(red: 0.10, green: 0.46, blue: 0.82))
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 12)
        }
        .frame(width: 432, height: 288)
    }

    private func detailRow(label: String, value: String, uppercaseLabel: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(uppercaseLabel ? label.uppercased() : label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(uppercaseLabel ? 0.5 : 0)
                .foregroundColor(.black.opacity(0.45))
                .frame(width: 130, alignment: .leading)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(.black.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }

    @ViewBuilder
    private var appIconView: some View {
        if let icon = AppIconLoader.load() {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: "creditcard.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(red: 0.10, green: 0.46, blue: 0.82))
                .frame(width: 18, height: 18)
        }
    }

    /// „Name · Bank" — verwendet die spezifische Bank-Bezeichnung (z.B.
    /// „Sparkasse Siegen") falls geliefert, sonst nur den Namen.
    private var recipientLabel: String {
        let n = receipt.recipientName.trimmingCharacters(in: .whitespaces)
        if let bank = receipt.recipientBankName?.nilIfEmpty {
            return n.isEmpty ? bank : "\(n) · \(bank)"
        }
        return n
    }

    /// Sender-Zeile: Nickname (falls gesetzt) + spezifische Bank.
    private var senderLabel: String {
        let bank = receipt.senderBankName
        if let nick = receipt.senderSlotNickname?.nilIfEmpty {
            return "\(nick) · \(bank)"
        }
        return bank
    }

    /// Wenn der User einen Termin gewählt hat → dessen Datum, sonst der
    /// Zeitpunkt der erfolgreichen Auslösung. So erscheint im Sofort-Fall
    /// die echte Sende-Uhrzeit, nicht „Sofort".
    private var datumValue: Date {
        receipt.scheduledDate ?? receipt.executedAt
    }

    private var disclaimerText: String {
        L10n.t(
            "Diese PDF bestätigt nur, dass die Überweisung von uns ausgelöst wurde. Bitte prüfe in deinem eigenen Konto, ob das Geld bereits angekommen ist — die Bank-Buchung kann je nach Institut Sekunden bis wenige Stunden dauern.",
            "This PDF confirms only that the transfer was initiated. Please check your own account whether the money has actually landed — depending on the banks, posting can take seconds to a few hours."
        )
    }

    private func shortIban(_ iban: String) -> String {
        let c = iban.replacingOccurrences(of: " ", with: "")
        guard c.count > 8 else { return iban }
        return "\(c.prefix(4)) \u{2026} \(c.suffix(4))"
    }

    private func formatEUR(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: AppLanguage.resolved() == .de ? "de_DE" : "en_US")
        f.dateFormat = "d. MMMM yyyy · HH:mm"
        return f.string(from: date)
    }
}
