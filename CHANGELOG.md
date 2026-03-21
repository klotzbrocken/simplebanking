# Changelog — simplebanking

All notable changes to this project will be documented in this file.
This project adheres to [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

---

## [1.2.3] — 2026-03-18

### Fixed
- `appcast.xml`: corrected GitHub Releases download URLs for Sparkle auto-update

---

## [1.2.1] — 2026-03-14

### Added
- Double-click on flyout card opens transaction panel directly
- Reference column (Verwendungszweck) shown in wide panel mode (≥ 840 px)

### Fixed
- Calendar heatmap: balance on the 1st of month was ~1,000 € too high (switched from value date to booking date)
- Calendar heatmap: days 1–5 missing due to ID collision in ForEach loops
- Calendar heatmap: first weekday of month displayed incorrectly
- Calendar heatmap: demo mode showed empty heatmap
- Calendar heatmap: close button was missing (sheet could only be dismissed via Escape)

---

## [1.2.0] — 2026-03-01

### Added
- **Calendar Heatmap** — 5th icon in transaction panel; monthly view with red (expenses) / green (income) intensity. Navigate months via `<` / `>`. Double-click on a day for a detail sheet with all transactions of that day.
- **Reference column** — In wide panel mode (840 px, green button) a reference/purpose column is shown between payee and amount.
- **Double-click on flyout card** — closes the popover and opens the transaction panel directly.
- **Balance update on refresh** — balance in the transaction panel is updated after a manual refresh.

### Changed
- "Reset" menu entry: removed redundant ⚠︎ emoji prefix; SF Symbol `exclamationmark.triangle` is kept as icon.

---

## [1.1.2] — 2026-02-25

### Fixed
- Sparkle version string format: build strings with hyphens were misinterpreted as pre-release tags, causing updates to be flagged as downgrades. Switched to `YYYYMMDD_HHMMSS_SEQ` format.
- `NSApp.activate` called before Sparkle update check to bring app to foreground reliably.
- URL prefix fix for Sparkle feed.

---

## [1.1.1] — 2026-02-24

### Changed
- Default refresh interval raised to 4 hours (240 min); labels now display "X hours".
- `RoutexClientError.Unauthorized` shown as readable UI message instead of raw error.
- All log output consolidated under `~/Library/Logs/simplebanking/` (no more Desktop log).

### Fixed
- Sparkasse credential flow reverted to browser redirect.
- YAXI trace ticket bug: the Trace service was creating a new ticket instead of reusing the original one.

---

## [1.1.0] — 2026-02-24

### Added
- Node.js/V8 backend fully replaced by `routex-client-swift` (RoutexClient 0.3.0) — no runtime dependency, smaller app bundle, no JIT entitlement required.
- New Swift source files: `YaxiService.swift`, `YaxiTicketMaker.swift`, `YaxiOAuthCallback.swift`.
- `sign-and-notarize.sh` no longer needs JIT entitlements.

---

[Unreleased]: https://github.com/klotzbrocken/simplebanking/compare/v1.2.3...HEAD
[1.2.3]: https://github.com/klotzbrocken/simplebanking/compare/v1.2.1...v1.2.3
[1.2.1]: https://github.com/klotzbrocken/simplebanking/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/klotzbrocken/simplebanking/compare/v1.1.2...v1.2.0
[1.1.2]: https://github.com/klotzbrocken/simplebanking/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/klotzbrocken/simplebanking/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/klotzbrocken/simplebanking/releases/tag/v1.1.0
