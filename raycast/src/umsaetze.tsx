import { List, Icon, ActionPanel, Action } from "@raycast/api";
import { useEffect, useMemo, useState } from "react";
import { Buchung, buchungen, Konto, konten, euro, SbFehlt } from "./sb";

const ALLE = "alle";

/** Eine Buchung als Zeile zum Weitergeben. Konto hinten, weil vorne das Wichtige steht. */
function alsText(b: Buchung, kontoName: string): string {
  const teile = [b.date, b.merchant, euro(b.amount, b.currency)];
  if (b.category) teile.push(b.category);
  if (kontoName) teile.push(kontoName);
  return teile.join(" · ");
}

export default function Umsaetze() {
  const [daten, setDaten] = useState<Buchung[]>([]);
  const [kontenListe, setKontenListe] = useState<Konto[]>([]);
  const [gewaehlt, setGewaehlt] = useState(ALLE);
  const [laedt, setLaedt] = useState(true);
  const [fehler, setFehler] = useState<string | undefined>();

  useEffect(() => {
    // Beides zusammen: Ohne die Kontenliste ließe sich weder filtern noch anzeigen,
    // zu welchem Konto eine Buchung gehört.
    Promise.all([buchungen(30), konten()])
      .then(([b, k]) => {
        setDaten(b);
        setKontenListe(k);
      })
      .catch((e) => setFehler(e instanceof SbFehlt ? e.message : String(e)))
      .finally(() => setLaedt(false));
  }, []);

  const namen = useMemo(() => new Map(kontenListe.map((k) => [k.slotId, k.name])), [kontenListe]);

  // Nur Konten anbieten, zu denen es im Zeitraum auch Buchungen gibt — ein leerer
  // Filter ist irreführender als ein fehlender Eintrag.
  const auswahl = useMemo(() => {
    const belegt = new Set(daten.map((b) => b.slotId));
    return kontenListe.filter((k) => belegt.has(k.slotId));
  }, [daten, kontenListe]);

  const sichtbar = useMemo(
    () => (gewaehlt === ALLE ? daten : daten.filter((b) => b.slotId === gewaehlt)),
    [daten, gewaehlt],
  );

  if (fehler) {
    return (
      <List>
        <List.EmptyView icon={Icon.ExclamationMark} title="Nicht erreichbar" description={fehler} />
      </List>
    );
  }

  return (
    <List
      isLoading={laedt}
      searchBarPlaceholder="Händler, Kategorie …"
      searchBarAccessory={
        auswahl.length > 1 ? (
          <List.Dropdown tooltip="Konto" value={gewaehlt} onChange={setGewaehlt}>
            <List.Dropdown.Item title="Alle Konten" value={ALLE} icon={Icon.BankNote} />
            <List.Dropdown.Section title="Konten">
              {auswahl.map((k) => (
                <List.Dropdown.Item key={k.slotId} title={k.name} value={k.slotId} icon={Icon.Building} />
              ))}
            </List.Dropdown.Section>
          </List.Dropdown>
        ) : undefined
      }
    >
      {sichtbar.map((b, i) => {
        const kontoName = namen.get(b.slotId) ?? "";
        return (
          <List.Item
            key={`${b.slotId}-${b.date}-${i}`}
            icon={b.status === "pending" ? Icon.Clock : Icon.Receipt}
            title={b.merchant}
            subtitle={b.category}
            accessories={[
              // Das Konto nur zeigen, solange nicht ohnehin danach gefiltert wird.
              ...(gewaehlt === ALLE && kontoName ? [{ tag: kontoName }] : []),
              { text: euro(b.amount, b.currency) },
              { text: b.date },
            ]}
            actions={
              <ActionPanel>
                <Action.CopyToClipboard title="Buchung Kopieren" content={alsText(b, kontoName)} />
                <Action.CopyToClipboard
                  title="Nur Betrag Kopieren"
                  content={euro(b.amount, b.currency)}
                  shortcut={{ modifiers: ["cmd"], key: "b" }}
                />
                <Action.CopyToClipboard
                  title="Nur Händler Kopieren"
                  content={b.merchant}
                  shortcut={{ modifiers: ["cmd"], key: "h" }}
                />
              </ActionPanel>
            }
          />
        );
      })}
    </List>
  );
}
