import Foundation

// MARK: - Was `sb --version` meldet
//
// Hier stand bis 2.2.2 ein Literal in der `CommandConfiguration` („1.5.0"). Niemand hat
// es mitgezogen: Die App war bei 2.2.2, das CLI meldete 1.5.0, und das fiel erst beim
// Rauchtest eines Builds auf. Genau dieselbe Falle wie die Routex-Zeile im Fehlerreport,
// die zwei Minor-Versionen lang „0.4.1" an YAXI geschickt hat (siehe
// `ErrorReportStore.routexSDKVersion`). Eine Versionsangabe, die von Hand gepflegt
// werden muss, ist über kurz oder lang falsch, und zwar ohne dass etwas fehlschlägt.
//
// Die Zahl steht deshalb nur noch an einer Stelle: in der Info.plist, die `build-app.sh`
// schreibt. Das CLI-Binary liegt in `simplebanking.app/Contents/MacOS/`, zwei
// Verzeichnisse unter der Plist, und `sb` ist ein Symlink darauf (`CLIInstaller`).
// Darum wird der Pfad erst aufgelöst.

enum CLIVersion {

    /// Fassung für `--version`, zusammengesetzt aus der Info.plist des App-Bundles,
    /// in dem dieses Binary liegt.
    static func text() -> String {
        let ausfuehrbar = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        return text(ausPlist: plist(neben: ausfuehrbar))
    }

    /// Die Info.plist zwei Ebenen über dem Binary, aber nur die von simplebanking.
    ///
    /// Der Kennungsvergleich ist kein Zierrat: Wer das Binary in ein fremdes Bundle
    /// kopiert, bekäme sonst dessen Version zu sehen.
    static func plist(neben ausfuehrbar: URL) -> [String: Any]? {
        let echt = ausfuehrbar.resolvingSymlinksInPath()
        let pfad = echt
            .deletingLastPathComponent()      // MacOS
            .deletingLastPathComponent()      // Contents
            .appendingPathComponent("Info.plist")
        guard let inhalt = NSDictionary(contentsOf: pfad) as? [String: Any],
              inhalt["CFBundleIdentifier"] as? String == "tech.yaxi.simplebanking"
        else { return nil }
        return inhalt
    }

    /// `nil` heißt: kein Bundle drumherum, also ein Entwicklungsbuild aus
    /// `swift build` oder `swift run`. Eine erfundene Zahl wäre dort schlechter als
    /// die Auskunft, dass es keine gibt.
    static func text(ausPlist plist: [String: Any]?) -> String {
        guard let kurz = plist?["CFBundleShortVersionString"] as? String, !kurz.isEmpty else {
            return "Entwicklungs-Build"
        }
        guard let build = plist?["CFBundleVersion"] as? String, !build.isEmpty else {
            return kurz
        }
        return "\(kurz) (\(build))"
    }
}
