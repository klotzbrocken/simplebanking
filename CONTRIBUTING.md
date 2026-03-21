# Contributing to simplebanking

Thank you for your interest in improving simplebanking! This document describes how to contribute effectively.

---

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [How to Report a Bug](#how-to-report-a-bug)
- [How to Request a Feature](#how-to-request-a-feature)
- [Development Workflow](#development-workflow)
- [Pull Request Guidelines](#pull-request-guidelines)
- [Commit Message Convention](#commit-message-convention)
- [Code Style](#code-style)

---

## Code of Conduct

Be respectful, constructive and welcoming. Harassment of any kind is not tolerated.

---

## Getting Started

1. **Fork** the repository and clone your fork:
   ```bash
   git clone https://github.com/<your-username>/simplebanking.git
   cd simplebanking
   ```
2. Create a feature branch:
   ```bash
   git checkout -b feat/your-feature-name
   ```
3. Set up secrets (required to build and run the app):
   ```bash
   ./make-secrets.sh "YOUR_YAXI_KEY_ID" "YOUR_YAXI_SECRET_BASE64"
   ```
4. Build the app bundle:
   ```bash
   ./build-app.sh
   # → SimpleBankingBuild/simplebanking.app
   ```

> **Note:** You need a YAXI Open Banking API key to connect to a real bank. For UI-only development you can use the built-in demo mode (`defaults write de.klotzbrocken.simplebanking demoMode -bool YES`).

---

## How to Report a Bug

1. Check [existing issues](https://github.com/klotzbrocken/simplebanking/issues) to avoid duplicates.
2. Open a [new issue](https://github.com/klotzbrocken/simplebanking/issues/new) and include:
   - macOS version and simplebanking version
   - Steps to reproduce
   - Expected vs. actual behaviour
   - Relevant log output from `~/Library/Logs/simplebanking/`

---

## How to Request a Feature

Open an issue with the label `enhancement` and describe:
- The problem you want to solve
- Your proposed solution (optional)
- Any alternatives you considered

---

## Development Workflow

```
main  ←  only merge-ready, reviewed code
  └─ feat/<name>   new features
  └─ fix/<name>    bug fixes
  └─ chore/<name>  maintenance, docs, tooling
```

1. Keep pull requests **focused** — one feature or fix per PR.
2. Update `CHANGELOG.md` under `## [Unreleased]` with your changes.
3. Make sure the app builds without warnings (`./build-app.sh`).
4. Test your changes manually in both **demo mode** and (if possible) with a real bank account.

---

## Pull Request Guidelines

- Target the `main` branch.
- Fill in the PR template (description, type of change, how to test).
- Link the related issue (e.g. `Closes #42`).
- Ensure no credentials, IBANs or API keys are committed — use `make-secrets.sh`.
- Screenshots or screen recordings are welcome for UI changes.

---

## Commit Message Convention

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <short summary>

[optional body]
[optional footer]
```

| Type | When to use |
|---|---|
| `feat` | New feature |
| `fix` | Bug fix |
| `docs` | Documentation only |
| `chore` | Build, tooling, dependencies |
| `refactor` | Code change without feature/fix |
| `perf` | Performance improvement |
| `test` | Adding or fixing tests |

Examples:
```
feat(heatmap): add month navigation with < / > buttons
fix(sparkle): correct version string format to YYYYMMDD_HHMMSS_SEQ
docs: add CONTRIBUTING guide
```

---

## Code Style

- **Swift** — follow the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/).
- Use `// MARK: -` sections to organise larger files.
- Prefer `async/await` over completion handlers for new code.
- No force unwraps (`!`) outside of `@IBOutlet` / `fatalError` contexts.
- Keep view logic out of model/service layers.

---

Questions? Open an issue or reach out via the repository discussions.
