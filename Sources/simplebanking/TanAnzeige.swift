import Foundation

/// Wann „TAN" in der Menüleiste steht und der Hinweis über der Umsatzliste erscheint.
///
/// Bis 02.09.2026 war das ein einzelnes `Bool`: Fragte *eine* Bank nach einer Freigabe,
/// stand der Hinweis bei jedem Konto — auch nachdem man längst zu einer anderen Bank
/// gewechselt hatte. Der Zustand gehört zum Konto, nicht zur App.
enum TanAnzeige {

    /// - Parameters:
    ///   - wartendeSlots: Konten, deren Bank gerade auf eine Freigabe wartet.
    ///   - aktiverSlot: das gerade angezeigte Konto.
    ///   - alleAktiv: Unified-Mode — dort sind alle Konten gleichzeitig zu sehen, also
    ///     ist eine Freigabe auf irgendeinem von ihnen für die Anzeige einschlägig.
    static func zeigen(wartendeSlots: Set<String>,
                       aktiverSlot: String,
                       alleAktiv: Bool) -> Bool {
        alleAktiv ? !wartendeSlots.isEmpty : wartendeSlots.contains(aktiverSlot)
    }
}
