import Foundation

/// Führt `transform` für jedes Element von `items` aus, aber mit **begrenzter
/// Parallelität** (gleitendes Fenster von `maxConcurrent` laufenden Tasks). Die
/// Ergebnisse werden in **Eingabereihenfolge** zurückgegeben — unabhängig davon,
/// welcher Task zuerst fertig wird.
///
/// Wirft `transform` einen Fehler, wird die gesamte Gruppe abgebrochen und der
/// Fehler propagiert (übrige Tasks werden gecancelt). Wer Einzelfehler tolerieren
/// will, fängt sie INNERHALB von `transform` ab und gibt z.B. einen Optional-Wert
/// zurück.
///
/// Motivation: serielle `for … await`-Schleifen über Netzwerk-Calls summieren die
/// Latenzen; volle `withTaskGroup`-Parallelität kann Server überfordern/rate-limiten.
/// Das Fenster ist der Mittelweg.
func boundedConcurrentMap<T: Sendable, R: Sendable>(
    _ items: [T],
    maxConcurrent: Int,
    _ transform: @escaping @Sendable (T) async throws -> R
) async throws -> [R] {
    if items.isEmpty { return [] }
    let window = max(1, maxConcurrent)
    var results = [R?](repeating: nil, count: items.count)

    try await withThrowingTaskGroup(of: (Int, R).self) { group in
        var next = 0
        func add(_ i: Int) {
            let item = items[i]
            group.addTask { (i, try await transform(item)) }
        }
        // Fenster initial füllen …
        while next < items.count && next < window { add(next); next += 1 }
        // … und bei jedem fertigen Task einen neuen nachrücken lassen.
        while let (i, r) = try await group.next() {
            results[i] = r
            if next < items.count { add(next); next += 1 }
        }
    }
    return results.compactMap { $0 }
}
