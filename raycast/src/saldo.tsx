import { List, Icon, Color } from "@raycast/api";
import { useEffect, useState } from "react";
import { Konto, konten, euro, SbFehlt } from "./sb";

export default function Saldo() {
  const [daten, setDaten] = useState<Konto[]>([]);
  const [laedt, setLaedt] = useState(true);
  const [fehler, setFehler] = useState<string | undefined>();

  useEffect(() => {
    konten()
      .then(setDaten)
      .catch((e) => setFehler(e instanceof SbFehlt ? e.message : String(e)))
      .finally(() => setLaedt(false));
  }, []);

  if (fehler) {
    return (
      <List>
        <List.EmptyView icon={Icon.ExclamationMark} title="Nicht erreichbar" description={fehler} />
      </List>
    );
  }

  const summe = daten.reduce((s, k) => s + k.balance, 0);

  return (
    <List isLoading={laedt} searchBarPlaceholder="Konto suchen">
      {daten.length > 1 && (
        <List.Section title="Gesamt">
          <List.Item icon={Icon.BankNote} title="Alle Konten" accessories={[{ text: euro(summe) }]} />
        </List.Section>
      )}
      <List.Section title="Konten">
        {daten.map((k) => (
          <List.Item
            key={k.slotId}
            icon={{
              source: Icon.Building,
              tintColor: k.balance < 0 ? Color.Red : Color.Green,
            }}
            title={k.name}
            subtitle={k.iban.slice(0, 8) + "…"}
            accessories={[{ text: euro(k.balance, k.currency) }]}
          />
        ))}
      </List.Section>
    </List>
  );
}
