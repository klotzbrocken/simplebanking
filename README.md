# BalanceBar (macOS Menu Bar) — GoCardless Bank Account Data (PSD2)

Goal: Show **current balance** in the macOS menu bar for a single account (Sparkasse Siegen / IBAN DE83460500010001808336), **no decimals**, refresh every **15 minutes**.

## How it will work (high level)
1. User completes GoCardless Bank Account Data consent (browser/SCA).
2. App stores the resulting **requisition_id** + **account_id** securely.
3. App fetches balances periodically and displays a formatted value like `1.234 €`.

## What I need from you
1. Create GoCardless Bank Account Data credentials (user secrets) in the portal:
   - https://bankaccountdata.gocardless.com/user-secrets/
2. Provide to the app (we’ll store in Keychain / env during dev):
   - `GOCARDLESS_SECRET_ID`
   - `GOCARDLESS_SECRET_KEY`

## Notes
- Access is typically valid for ~90 days per bank (then re-consent).
- We should cache the last known balance and show `— €` if refresh fails.
