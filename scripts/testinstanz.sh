#!/bin/bash
#
# Leere Testinstanz von simplebanking — für Einrichtung und MoneyMoney-Import,
# ohne die echten Daten zu berühren.
#
# Warum es ein Skript braucht: Der Einrichtungsassistent erscheint nur, wenn
# `CredentialsStore.exists()` falsch ist, und der MoneyMoney-Schritt nur beim
# **Erstlauf** — beim Hinzufügen eines Kontos führt der Weg direkt zur Banksuche
# (`existingMasterPassword != nil ? .bankSearch : .welcome`). Eine Testinstanz muss
# also an zwei Stellen leer sein:
#
#   1. Dateien  — die App beachtet `SIMPLEBANKING_APP_SUPPORT_DIR` (gemessen:
#                 legt dort eine eigene transactions.db an). Deine echten Dateien
#                 werden dabei nicht einmal gelesen.
#   2. Einstellungen — dafür gibt es keine Umlenkung. Die Domain `tech.yaxi.simplebanking`
#                 wird gesichert, geleert und von `stop` zurückgeholt. Liefe sie
#                 ungeleert, stünden Deine vier Slots ohne Zugangsdaten da, und die
#                 Testinstanz schriebe ihre neuen Slots in Deine echten Einstellungen.
#
# Deshalb nicht gleichzeitig: Beide Instanzen teilen dieselbe Einstellungs-Domain.
# `start` beendet die laufende App, `stop` holt sie zurück.
#
# **Touch ID in der Testinstanz nicht einschalten.** Das Hauptkennwort liegt im
# Schlüsselbund unter Dienst `tech.yaxi.simplebanking`, Konto `master-password` —
# eine Bequemlichkeitskopie, die eine Testinstanz überschreiben würde. Reparierbar
# (einmal echtes Kennwort eingeben), aber unnötig. Das **MoneyMoney**-Kennwort ist
# davon nicht betroffen: Es wird getippt, einmal benutzt und nirgends gespeichert.
#
set -euo pipefail

DOMAIN="tech.yaxi.simplebanking"
ECHT="$HOME/Library/Application Support/simplebanking"
SICHERUNG="$HOME/simplebanking-testsicherung"
TESTDATEN="$HOME/simplebanking-testinstanz"
WURZEL="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="$WURZEL/SimpleBankingBuild/simplebanking.app"
APP_BIN="$APP_BUNDLE/Contents/MacOS/simplebanking"

testinstanz_starten() {
    FASSUNG="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
                 "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo '?')"
    BAU="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' \
             "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo '?')"
    echo
    echo "Testinstanz startet: Fassung $FASSUNG (Bau $BAU)"
    echo "  → Ist das nicht der Stand, den Du prüfen willst: erst 'bash build-app.sh'."
    echo "Daten liegen in $TESTDATEN"

    # `nohup` und `disown`, sonst ist die App weg, sobald das Skript ausläuft: Das
    # Terminal räumt beim Beenden die Prozessgruppe ab, und ein `&` allein schützt
    # davor nicht. Gemessen am 11.11.2026 — die App startete, legte ihre Datenbank
    # an und war sofort wieder beendet, ohne Absturzbericht. „Passiert nix" war
    # genau das.
    SIMPLEBANKING_APP_SUPPORT_DIR="$TESTDATEN" nohup "$APP_BIN" >/dev/null 2>&1 &
    disown 2>/dev/null || true

    # Gegenprobe statt Hoffnung: „passiert nix" ist keine Fehlermeldung.
    sleep 3
    if pgrep -f 'simplebanking\.app/Contents/MacOS/simplebanking$' >/dev/null; then
        echo
        echo "Läuft. Das Symbol steht in der Menüleiste, der Assistent sollte offen sein."
        echo "Zurück zum echten Stand:  bash $0 stop"
    else
        echo
        echo "Die Testinstanz ist nicht hochgekommen." >&2
        echo "Protokoll:  log show --last 2m --predicate 'process == \"simplebanking\"' | tail -40" >&2
        exit 1
    fi
}

app_beenden() {
    osascript -e "tell application \"simplebanking\" to quit" >/dev/null 2>&1 || true
    sleep 1
    pkill -f 'simplebanking\.app/Contents/MacOS/simplebanking$' >/dev/null 2>&1 || true
    sleep 1
}

case "${1:-}" in
start)
    [[ -x "$APP_BIN" ]] || { echo "Kein Bau unter $APP_BUNDLE — vorher: bash build-app.sh" >&2; exit 1; }

    # Die wichtigste Zeile des Skripts: Ein zweites `start` würde die gute
    # Sicherung mit dem leeren Teststand überschreiben. Dann wären die echten
    # Einstellungen weg und niemand hätte es gemerkt.
    if [[ -e "$SICHERUNG" ]]; then
        echo "Es liegt schon eine Sicherung in $SICHERUNG." >&2
        echo "Erst 'bash scripts/testinstanz.sh stop', dann neu starten." >&2
        exit 1
    fi

    echo "simplebanking beenden…"
    app_beenden

    mkdir -p "$SICHERUNG"
    if [[ -d "$ECHT" ]]; then
        echo "Daten sichern → $SICHERUNG/simplebanking"
        cp -R "$ECHT" "$SICHERUNG/simplebanking"
    else
        echo "Kein echter Datenordner vorhanden (nichts zu sichern)."
    fi

    echo "Einstellungen sichern → $SICHERUNG/einstellungen.plist"
    defaults export "$DOMAIN" "$SICHERUNG/einstellungen.plist"
    # Gegenprobe, bevor irgendetwas gelöscht wird.
    plutil -lint "$SICHERUNG/einstellungen.plist" >/dev/null

    echo "Einstellungen leeren"
    defaults delete "$DOMAIN" >/dev/null 2>&1 || true
    killall cfprefsd >/dev/null 2>&1 || true
    sleep 1

    rm -rf "$TESTDATEN"
    mkdir -p "$TESTDATEN"

    # Diagnose an: Ab Werk ist sie aus, und dann schweigt das Protokoll über genau
    # die Schritte, bei denen man wissen will, wo es steht. In einer Testinstanz
    # ist das die falsche Vorgabe.
    defaults write "$DOMAIN" appLoggingEnabled -bool YES

    testinstanz_starten
    ;;

neustart)
    # Zweiter Durchlauf mit dem Stand, den `start` schon vorbereitet hat: Sicherung
    # bleibt liegen, Einstellungen bleiben leer, nur die Testdaten werden frisch.
    [[ -x "$APP_BIN" ]] || { echo "Kein Bau unter $APP_BUNDLE — vorher: bash build-app.sh" >&2; exit 1; }
    [[ -f "$SICHERUNG/einstellungen.plist" ]] || {
        echo "Keine Sicherung in $SICHERUNG — benutze 'start'." >&2; exit 1; }

    echo "Testinstanz beenden…"
    app_beenden
    echo "Testdaten wegwerfen und neu anlegen"
    rm -rf "$TESTDATEN"
    mkdir -p "$TESTDATEN"
    # Ein vorheriger Durchlauf hat Slots in die Einstellungen geschrieben — ohne
    # dieses Leeren zeigt die App den Assistenten nicht mehr.
    defaults delete "$DOMAIN" >/dev/null 2>&1 || true
    killall cfprefsd >/dev/null 2>&1 || true
    sleep 1
    defaults write "$DOMAIN" appLoggingEnabled -bool YES
    testinstanz_starten
    ;;

stop)
    [[ -f "$SICHERUNG/einstellungen.plist" ]] || {
        echo "Keine Sicherung in $SICHERUNG — nichts zurückzuholen." >&2; exit 1; }

    echo "Testinstanz beenden…"
    app_beenden

    echo "Einstellungen zurückholen"
    defaults delete "$DOMAIN" >/dev/null 2>&1 || true
    defaults import "$DOMAIN" "$SICHERUNG/einstellungen.plist"
    killall cfprefsd >/dev/null 2>&1 || true
    sleep 1

    # Der echte Datenordner wurde nie angefasst — die Kopie bleibt trotzdem
    # liegen, bis Du sie selbst wegwirfst. Eine Sicherung, die das Skript
    # aufräumt, ist keine.
    echo "Echte App starten…"
    # Über LaunchServices, nicht über den Bau im Projektordner: Gemeint ist die
    # Kopie, die Du sonst benutzt.
    open -a simplebanking >/dev/null 2>&1 || \
        echo "  (konnte simplebanking nicht starten — von Hand öffnen)"

    echo
    echo "Fertig. Die Sicherung liegt weiter in $SICHERUNG"
    echo "Teststand (kann weg):      $TESTDATEN"
    ;;

*)
    echo "Aufruf: bash $0 start|neustart|stop"
    echo
    echo "  start     sichert Deinen Stand, leert alles, startet die Testinstanz"
    echo "  neustart  zweiter Durchlauf mit frischen Testdaten (Sicherung bleibt)"
    echo "  stop      holt Deinen echten Stand zurück und startet die echte App"
    exit 1
    ;;
esac
