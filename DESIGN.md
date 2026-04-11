# simplebanking — Design System

**Direction:** Stilles Morgenlicht (Still Morning Light)
**Last updated:** 2026-03-30
**Status:** Approved

---

## Philosophy

Most banking apps default to icy blue and clinical gray — "trust" signaled through conservative convention. simplebanking takes the opposite bet: warmth signals safety. A calm, warm-tinted UI feels like checking your account over morning coffee, not logging into a corporate portal.

The menu bar popover is an underdesigned surface in almost every finance app on macOS. We treat it as a premium product surface, not a utility widget.

---

## Color Palette

### Light Mode

| Token | Hex | Usage |
|-------|-----|-------|
| `bg` | `#F5F2EC` | App background, popover fill |
| `surface` | `#EDE9E0` | Cards, input backgrounds |
| `text-primary` | `#1A1712` | Headings, balance figures |
| `text-secondary` | `#7A7468` | Labels, metadata, "Aggregierter Kontostand" |
| `income` | `#3D6B4F` | Positive amounts |
| `expense` | `#8B3A2A` | Negative amounts |
| `accent` | `#4A6FA5` | Interactive elements, active states |

### Dark Mode

| Token | Hex | Usage |
|-------|-----|-------|
| `bg` | `#18160F` | App background, popover fill |
| `surface` | `#221F16` | Cards, input backgrounds |
| `text-primary` | `#F0EDE4` | Headings, balance figures |
| `text-secondary` | `#8A8278` | Labels, metadata |
| `income` | `#5A9970` | Positive amounts |
| `expense` | `#C4614D` | Negative amounts |
| `accent` | `#6B8EC4` | Interactive elements, active states |

### Semantic Colors (Swift)

```swift
// Income / Expense
Color(hex: "3D6B4F") // light income
Color(hex: "8B3A2A") // light expense
Color(hex: "5A9970") // dark income
Color(hex: "C4614D") // dark expense

// Use NSColor.controlBackgroundColor for system-adaptive surfaces
// where custom bg tokens would break system theming expectations
```

---

## Typography

### Balance Figures
- **Font:** New York (Apple system serif, macOS 13+)
- **Sizes:** 32pt (unified total), 20pt (per-account in unified card), 18pt (single account)
- **Weight:** Bold
- **Always:** `.monospacedDigit()` — prevents layout shift as digits change

```swift
Text(formattedBalance)
    .font(.system(size: 32, weight: .bold, design: .serif))
    .monospacedDigit()
```

### Labels and UI Text
- **Font:** SF Pro Rounded (system default on macOS)
- **Primary labels:** 13pt semibold
- **Secondary labels:** 12pt regular
- **Metadata (dates, categories):** 11pt regular, `text-secondary` color

### Transaction Amounts
- **Font:** SF Pro, 13pt
- **Always:** `.monospacedDigit()`
- **Income:** `income` token color
- **Expense:** `expense` token color

---

## Component Specs

### Balance Card (Unified Mode)

```
┌─────────────────────────────────────┐
│ ▌ 🏦 Sparkasse     €3.241,20        │  ← 3px color bar + logo + nick + balance
│ ▌ 🏦 N26           €1.580,13        │  ← same for each slot
│                                     │
│ € 4.821,33                          │  ← 32pt New York bold
│ Aggregierter Kontostand             │  ← 13pt secondary
└─────────────────────────────────────┘
```

- Color bars: 3px wide, 18px tall, `clipShape(RoundedRectangle(cornerRadius: 1.5))`
- Per-slot balance: 14pt monospaced, secondary color
- Total: 32pt serif bold, primary color
- Spacing between icon strip and total: 8pt

### Balance Card (Single Mode)

```
┌─────────────────────────────────────┐
│ 🏦 Sparkasse     14:32              │  ← logo + bank name + last refresh
│                                     │
│ € 3.241,20                          │  ← 32pt New York bold
│ Gutes Polster                       │  ← sentiment label, secondary color
└─────────────────────────────────────┘
```

### Transaction Row

```
│ ▌ REWE              Heute    -€ 43,20  │
│   Lebensmittel                         │
```

- Left border: 3px color bar for the account (same color as card)
- Merchant name: 13pt primary, bold
- Amount: 13pt monospaced, income/expense token
- Date: relative ("Heute", "Gestern", "Mo.") — 11pt secondary
- Category: 11pt secondary, second line

### Transaction List Header

```
│                     [↑] [⚡] [▣] │
```

- No heading text ("Umsätze" removed — obvious from context)
- No pagination numbers
- Right-aligned icon row: Export (square.and.arrow.up), Filter (line.3.horizontal.decrease.circle), Unified toggle (rectangle.stack)
- Icon size: 15pt, `NSColor.secondaryLabelColor`

---

## Interaction Principles

**Relative dates everywhere.** "Heute", "Gestern", "Mo.", "Di." — not "2026-03-28". Reduces cognitive load.

**Color as signal, not decoration.** The 3px account color bar ties a transaction back to its source account at a glance. Income/expense colors are consistent throughout.

**Unified mode is discovered, not forced.** Auto-enables when user adds a second account. Resets when navigating between accounts with the arrows. The toggle in the header is the on-ramp.

**No addAccount button in the UI.** Adding accounts is a settings action, not a transaction-browsing action. Settings panel is the only entry point.

---

## Bank Color System

Auto-generated from bank logo hues via `GeneratedBankColors.swift`. Priority chain:

1. User-chosen `customColor` (hex string in `BankSlot`)
2. `GeneratedBankColors.color(for: logoId)` — extracted from logo
3. Gray fallback (`#8A8278`)

User can override via the color picker in Settings (next to the pencil icon for each account).

---

## Research Notes

**Why warm instead of blue?** Competitive analysis (2024-2025) shows warmth is the emerging differentiator in challenger finance apps. Monzo, Wealthsimple, Monobank all moved toward earthy palettes. Blue is now the default institutional signal — warmth reads as *personal* rather than *corporate*.

**Why serif for balances?** New York at 32pt on a warm background reads as premium and deliberate. SF Pro at the same size reads like a calculator. The balance figure is the product — it deserves typographic attention.

**Why warm dark mode?** Every other macOS finance app uses Material-style dark gray (#1C1C1E). A warm dark brown (#18160F) is immediately distinctive. Still calm, not garish.

**Menu bar popover as premium surface.** Almost no macOS menu bar finance apps invest in the popover's visual identity. This is unclaimed territory.

---

## Implementation Status

| Component | Status |
|-----------|--------|
| 3px account color bars (transaction rows) | ✅ Shipped |
| 3px account color bars (unified balance card) | ✅ Shipped |
| Bank color system (GeneratedBankColors + customColor) | ✅ Shipped |
| Custom color picker in Settings | ✅ Shipped |
| Unified balance card (icons → total → label) | ✅ Shipped |
| Unified mode auto-reset on account switch | ✅ Shipped |
| Transaction header (no heading, right-aligned icons) | ✅ Shipped |
| Remove balance privacy toggle | ✅ Shipped |
| Remove + add account button | ✅ Shipped |
| New York serif for balance figures | ⬜ Pending |
| Warm color palette (#F5F2EC bg etc.) | ⬜ Pending |
| Relative dates in transaction rows | ⬜ Pending |
| Income/expense color tokens | ⬜ Pending |
