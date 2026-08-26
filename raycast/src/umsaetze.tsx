import { List, Icon } from "@raycast/api";
import { useEffect, useState } from "react";
import { Buchung, buchungen, euro, SbFehlt } from "./sb";

export default function Umsaetze() {
  const [daten, setDaten] = useState<Buchung[]>([]);
  const [laedt, setLaedt] = useState(true);
  const [fehler, setFehler] = useState<string | undefined>();

  useEffect(() => {
    buchungen(30)
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

  return (
    <List isLoading={laedt} searchBarPlaceholder="Händler, Kategorie …">
      {daten.map((b, i) => (
        <List.Item
          key={`${b.slotId}-${b.date}-${i}`}
          icon={b.status === "pending" ? Icon.Clock : Icon.Receipt}
          title={b.merchant}
          subtitle={b.category}
          accessories={[{ text: euro(b.amount, b.currency) }, { text: b.date }]}
        />
      ))}
    </List>
  );
}
