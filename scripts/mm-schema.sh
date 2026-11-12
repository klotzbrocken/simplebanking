#!/bin/bash
#
# Zeigt, wie MoneyMoney seine Kategorien ablegt — Struktur und Zeilenzahlen,
# sonst nichts.
#
# Was ausgegeben wird: Tabellennamen, Spaltennamen, Anzahl der Zeilen je Tabelle
# und die Verteilung von `group_key`. KEINE Kategorienamen, keine Umsätze, keine
# Beträge. Das Kennwort wird getippt (`read -s`), nie als Argument übergeben —
# Argumente stehen in `ps` für jeden Prozess der Sitzung.
#
# MoneyMoney vorher beenden: Bei laufender App liegt ein `-journal` daneben, und
# eine Datenbank mit unaufgeräumtem Journal lässt sich nicht nur-lesend öffnen.
set -euo pipefail

DB="$HOME/Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney/Database/MoneyMoney.sqlite"
SQLCIPHER="$(command -v sqlcipher || echo /opt/homebrew/bin/sqlcipher)"

[[ -r "$DB" ]] || { echo "MoneyMoney-Datenbank nicht gefunden: $DB" >&2; exit 1; }
[[ -x "$SQLCIPHER" ]] || { echo "sqlcipher fehlt — brew install sqlcipher" >&2; exit 1; }
if pgrep -qf '/MoneyMoney.app/Contents/MacOS/MoneyMoney'; then
    echo "MoneyMoney läuft. Bitte erst beenden, sonst ist die Datenbank gesperrt." >&2
    exit 1
fi

printf 'MoneyMoney-Kennwort: ' >&2
read -rs KENNWORT
echo >&2

"$SQLCIPHER" "$DB" <<SQL
PRAGMA key = '$KENNWORT';
.headers on
.mode list
SELECT '=== Tabellen mit Kategoriebezug ===';
SELECT name FROM sqlite_master WHERE type='table' AND name LIKE '%categ%' ORDER BY name;
SELECT '=== Alle Tabellen ===';
SELECT group_concat(name, ', ') FROM (SELECT name FROM sqlite_master WHERE type='table' ORDER BY name);
SELECT '=== Spalten: categories ===';
PRAGMA table_info(categories);
SELECT '=== Spalten: category_groups ===';
PRAGMA table_info(category_groups);
SELECT '=== Zeilen ===';
SELECT 'categories', count(*) FROM categories;
SELECT 'category_groups', count(*) FROM category_groups;
SELECT '=== categories: Namen leer? ===';
SELECT (name IS NULL OR name='') AS ohne_namen, count(*) FROM categories GROUP BY 1;
SELECT '=== categories: group_key-Verteilung ===';
SELECT group_key, count(*) FROM categories GROUP BY 1 ORDER BY 1 LIMIT 20;
SELECT '=== category_groups: Namen leer? ===';
SELECT (name IS NULL OR name='') AS ohne_namen, count(*) FROM category_groups GROUP BY 1;
SELECT '=== category_groups: group_key-Verteilung ===';
SELECT group_key, count(*) FROM category_groups GROUP BY 1 ORDER BY 1 LIMIT 20;
SELECT '=== Umsätze: category_key gesetzt? ===';
SELECT (category_key IS NULL OR category_key=0) AS ohne, count(*) FROM transactions GROUP BY 1;
SELECT '=== Umsätze: benannte oder namenlose Kategorie? ===';
SELECT CASE WHEN c.rowid IS NULL THEN 'kein Treffer'
            WHEN c.name IS NULL OR c.name='' THEN 'namenlose Kategorie'
            ELSE 'benannte Kategorie' END AS art, count(*)
  FROM transactions t LEFT JOIN categories c ON c.rowid = t.category_key
 GROUP BY 1 ORDER BY 2 DESC;
SELECT '=== Umsätze: wie viele verschiedene Kategorieschlüssel? ===';
SELECT count(DISTINCT category_key) FROM transactions;
SELECT '=== Benannte Kategorie: vor oder nach der Naht (2026-09-14)? ===';
SELECT CASE WHEN c.name IS NULL OR c.name='' THEN 'namenlos' ELSE 'benannt' END AS art,
       CASE WHEN date(t.timestamp,'unixepoch') < '2026-09-14' THEN 'vor der Naht'
            ELSE 'ab der Naht' END AS zeitraum,
       count(*)
  FROM transactions t LEFT JOIN categories c ON c.rowid = t.category_key
 GROUP BY 1, 2 ORDER BY 3 DESC;
SELECT '=== Wohin zeigt category_key? (Treffer je Tabelle) ===';
SELECT 'passt auf categories.rowid', count(*) FROM transactions t
  WHERE t.category_key IN (SELECT rowid FROM categories);
SELECT 'passt auf category_groups.rowid', count(*) FROM transactions t
  WHERE t.category_key IN (SELECT rowid FROM category_groups);
SQL
