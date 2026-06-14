# simplebanking startet nicht / kein Menüleisten-Symbol — Diagnose-Daten sammeln

Danke für die Meldung! Damit ich das schnell beheben kann, brauche ich ein paar
Diagnose-Daten von deinem Mac. Dauert ca. 2 Minuten, ist ungefährlich — es werden
**keine** Bankdaten oder Passwörter übertragen.

## So geht's

1. Starte simplebanking ganz normal (Doppelklick), auch wenn nichts in der
   Menüleiste erscheint. **Lass die App im „hängenden" Zustand offen** — nicht
   beenden.
2. Öffne das Programm **Terminal** (⌘+Leertaste → „Terminal").
3. Kopiere den folgenden Befehl **komplett** hinein und drücke Enter:

```bash
DEST=~/Desktop/simplebanking-diagnose-$(date +%Y%m%d-%H%M); mkdir -p "$DEST"; \
PID=$(pgrep -x simplebanking | head -1); \
if [ -n "$PID" ]; then echo "✅ simplebanking läuft (PID $PID) — erstelle Sample…"; \
  sample "$PID" 5 -file "$DEST/sample.txt"; \
else echo "⚠️  simplebanking läuft gerade NICHT. Bitte starten und Befehl erneut ausführen." | tee "$DEST/HINWEIS-app-lief-nicht.txt"; fi; \
if [ -d ~/Library/Logs/simplebanking ]; then cp -R ~/Library/Logs/simplebanking "$DEST/app-logs"; echo "✅ App-Logs kopiert."; \
else echo "ℹ️  Keine App-Logs gefunden." | tee "$DEST/HINWEIS-keine-app-logs.txt"; fi; \
if ls ~/Library/Logs/DiagnosticReports/simplebanking-* >/dev/null 2>&1; then cp ~/Library/Logs/DiagnosticReports/simplebanking-* "$DEST/"; echo "✅ Crash-Reports kopiert."; \
else echo "ℹ️  Keine Crash-Reports."; fi; \
echo "----------"; ls -l "$DEST"; echo "FERTIG → $DEST"
```

4. Nach „**FERTIG**" liegt auf deinem Schreibtisch ein Ordner
   `simplebanking-diagnose-…`.
5. Zieh ihn in eine **E-Mail an maik.klotz@gmail.com** (oder vorher per
   Rechtsklick → „… komprimieren").

> Wichtig: Die App muss **währenddessen geöffnet** sein, sonst kann kein Sample
> erstellt werden. Kommt „⚠️ läuft gerade NICHT", starte simplebanking und führe
> den Befehl erneut aus. Wenn am Ende nur eine `sample.txt` drin liegt, ist das
> völlig okay — sie ist das Wichtigste.

## Sofort-Workaround (optional, mit Vorsicht)

Wenn du nicht warten willst: ein voller Reset löst den Hänger, **löscht aber die
lokale Einrichtung** (Konten musst du neu hinterlegen; deine Bankdaten selbst sind
nicht betroffen):

```bash
defaults delete tech.yaxi.simplebanking 2>/dev/null; \
  rm -rf ~/Library/Application\ Support/simplebanking
```

Danach App neu starten und neu einrichten. **Nur wenn die Diagnose-Daten oben
schon gesichert sind** — sonst geht die Fehler-Grundlage verloren.

---

## Auswertung (intern)

`sample.txt` zeigt, **wo** der Main-Thread steht:
- in `runModal` / `MasterPasswordPanel` → Unlock-Dialog startet zu früh.
- in `SecItemCopyMatching` / Keychain → Keychain-ACL nach Update invalidiert.
- gesunder Idle-Loop (`nextEventMatchingMask` → `mach_msg`) → **kein** Hang;
  dann ist `applicationDidFinishLaunching` vermutlich gar nicht durchgelaufen
  (Status-Item nie erzeugt) → andere Ursache.

In `app-logs/` ist die letzte Zeile entscheidend: steht dort
`Application did finish launching` und danach nichts → Hang **innerhalb** des
Starts. Fehlt die Datei ganz → entweder läuft didFinishLaunching nicht, oder der
Logger schreibt nicht. `simplebanking-*.crash` (falls vorhanden) nennt den
exakten Frame.
