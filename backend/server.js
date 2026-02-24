import express from 'express'
import jwt from 'jsonwebtoken'
import { v4 as uuidv4 } from 'uuid'
import dotenv from 'dotenv'
import fs from 'node:fs'
import path from 'node:path'
import { exec } from 'node:child_process'
import { makeClient } from './yaxi.js'

function b64FromU8(u8) {
  return Buffer.from(u8).toString('base64')
}
function u8FromB64(b64) {
  return new Uint8Array(Buffer.from(b64, 'base64'))
}

dotenv.config({ path: '.env.local' })

const app = express()
app.use((req, res, next) => {
  console.log(`[Request] ${req.method} ${req.url}`)
  next()
})
app.use(express.json({ limit: '256kb' }))

let lastBalancesStatus = { at: null }
let lastTransactionsStatus = { at: null }
// Prevent opening the redirect URL multiple times within the same setup session.
let lastRedirectOpenedAt = 0
// Last OAuth callback params received from the bank's redirect.
let lastCallbackParams = null

const keyId = process.env.YAXI_KEY_ID
const secretB64 = process.env.YAXI_SECRET_BASE64
const port = Number(process.env.PORT || 8787)

if (!keyId || !secretB64) {
  console.error('Missing YAXI_KEY_ID or YAXI_SECRET_BASE64 in .env.local')
  process.exit(1)
}

const hmacKey = Buffer.from(secretB64, 'base64')

function decodeResultJwt(resultJwt) {
  try {
    return jwt.verify(resultJwt, hmacKey, { algorithms: ['HS256'] })
  } catch {
    // Fallback: decode ohne Verifikation (z.B. bei abweichendem Algorithmus von YAXI)
    return jwt.decode(resultJwt)
  }
}

const STATE_PATH = path.join(process.cwd(), 'state.json')

function loadState() {
  // Versuche zunächst state.json, dann das Backup bei korrupter Datei
  for (const p of [STATE_PATH, STATE_PATH + '.bak']) {
    if (!fs.existsSync(p)) continue
    try {
      return JSON.parse(fs.readFileSync(p, 'utf8'))
    } catch {
      console.error(`[State] ${p} ist korrupt, überspringe`)
    }
  }
  return {}
}

function saveState(s) {
  const json = JSON.stringify(s, null, 2)
  const tmp = STATE_PATH + '.tmp'
  fs.writeFileSync(tmp, json, 'utf8')
  // Atomarer Austausch: rename ist auf POSIX atomar
  fs.renameSync(tmp, STATE_PATH)
}

// Keep session and connectionData in state so the app can resume an existing bank dialog
// across refresh cycles and app restarts (when still valid).
let inMemorySessionBase64 = null

function preferredSessionBase64(state, requestSessionBase64) {
  if (typeof requestSessionBase64 === 'string' && requestSessionBase64.length > 0) return requestSessionBase64
  if (typeof inMemorySessionBase64 === 'string' && inMemorySessionBase64.length > 0) return inMemorySessionBase64
  if (typeof state.sessionBase64 === 'string' && state.sessionBase64.length > 0) return state.sessionBase64
  return null
}

function preferredConnectionDataBase64(state, requestConnectionDataBase64) {
  if (typeof requestConnectionDataBase64 === 'string' && requestConnectionDataBase64.length > 0) return requestConnectionDataBase64
  if (typeof state.connectionDataBase64 === 'string' && state.connectionDataBase64.length > 0) return state.connectionDataBase64
  return null
}

function normalizeOptionalText(value) {
  if (typeof value !== 'string') return null
  const trimmed = value.trim()
  return trimmed.length > 0 ? trimmed : null
}

function normalizeCredentialModel(rawModel) {
  const model = (rawModel && typeof rawModel === 'object') ? rawModel : {}
  return {
    full: model.full === true,
    userId: model.userId === true,
    none: model.none === true
  }
}

function resolvedCredentialModel(state) {
  const model = normalizeCredentialModel(state.connectionCredentialsModel)
  if (model.full || model.userId || model.none) {
    return model
  }
  // Backward-compatible default for state files without credential metadata.
  return { full: true, userId: true, none: false }
}

function buildCredentialsForConnection(state, userId, password, requestConnectionDataBase64) {
  const model = resolvedCredentialModel(state)
  const normalizedUserId = normalizeOptionalText(userId)
  const normalizedPassword = normalizeOptionalText(password)

  const connectionDataB64 = preferredConnectionDataBase64(state, requestConnectionDataBase64)
  const credentials = {
    connectionId: state.connectionId,
    connectionData: connectionDataB64 ? u8FromB64(connectionDataB64) : undefined
  }

  // Credentials are sent directly (full path) only when:
  //   a) connectionData already exists (recurring consent established via prior redirect), OR
  //   b) the bank does not support the redirect flow (none: false, e.g. C24)
  // For redirect-capable banks (none: true) without existing connectionData the first
  // request MUST go through the redirect flow to establish the recurring consent.
  // Sending credentials directly in that case gives Unauthorized because no consent exists.
  const hasConnectionData = !!connectionDataB64
  if (normalizedUserId && normalizedPassword && (!model.none || hasConnectionData)) {
    credentials.userId = normalizedUserId
    credentials.password = normalizedPassword
  } else if (model.none) {
    // No consent yet (or no credentials) — bank handles auth via Redirect flow.
  } else if (model.full) {
    if (normalizedUserId) credentials.userId = normalizedUserId
    if (normalizedPassword) credentials.password = normalizedPassword
  } else if (model.userId) {
    if (normalizedUserId) credentials.userId = normalizedUserId
    // Also pass password when provided – some banks (N26, DKB) report
    // userId-only but still require the password for SCA to trigger.
    if (normalizedPassword) credentials.password = normalizedPassword
  } else {
    // Unknown/legacy model: pass through optional credentials.
    if (normalizedUserId) credentials.userId = normalizedUserId
    if (normalizedPassword) credentials.password = normalizedPassword
  }

  return { model, credentials, normalizedUserId, normalizedPassword }
}

function validateCredentialInput(model, normalizedUserId, normalizedPassword) {
  // none:true means bank handles auth via Redirect — no credentials required or expected
  if (model.none) return null
  if (model.full) {
    if (!normalizedUserId || !normalizedPassword) {
      return 'missing userId/password'
    }
  }
  if (!model.full && model.userId && !normalizedUserId) {
    return 'missing userId'
  }
  return null
}

function isUserIdUnsupportedError(msg) {
  const text = String(msg || '').toLowerCase()
  return text.includes('does not support a user id') ||
    text.includes('does not support a userid') ||
    text.includes('supports no user id') ||
    text.includes('user id is not supported') ||
    text.includes('user id and a password')
}

function isObsoleteSessionError(msg) {
  const text = String(msg || '').toLowerCase()
  return text.includes('dialog-id ist nicht g') ||
    text.includes('dialog abgebrochen') ||
    text.includes('dialog-id is not valid') ||
    text.includes('dialog cancelled')
}

// Poll confirmBalances/confirmTransactions after a Redirect or RedirectHandle.
// User has been redirected to the bank's auth URL — poll for up to ~300 s.
async function handleSCARedirectPoll(ctxB64, service, client, ticket) {
  for (let i = 0; i < 60; i++) {
    await new Promise(r => setTimeout(r, 5000))
    const next = service === 'balances'
      ? await client.confirmBalances({ ticket, context: u8FromB64(ctxB64) })
      : await client.confirmTransactions({ ticket, context: u8FromB64(ctxB64) })
    const nextJson = next.toJSON()

    if (nextJson?.Result) return { result: nextJson }

    // Still waiting — update context and keep polling
    if (nextJson?.Redirect || nextJson?.RedirectHandle) {
      ctxB64 = nextJson?.Redirect?.context ?? nextJson?.RedirectHandle?.context ?? ctxB64
      continue
    }

    // Moved to Confirmation (decoupled push after redirect approval)
    if (nextJson?.Dialog?.input?.Confirmation) {
      return handleSCAFlow(nextJson, service, client, ticket, 0)
    }

    return { error: 'Unexpected response during redirect polling' }
  }
  return { error: 'SCA confirmation timeout — bitte öffne deine Sparkasse-App oder Banking-Webseite und bestätige den Zugriff. Falls das Browserfenster nicht mehr offen ist, bitte neu verbinden.' }
}

// Auto-resolve SCA interrupts:
//   Selection  → bank asks "which TAN method?" → auto-pick push/app/decoupled → recurse
//   Confirmation → decoupled push, poll up to ~60 s → recurse
// Returns { result: resultJson } on success, { error: string } on failure.
async function handleSCAFlow(json, service, client, ticket, depth = 0) {
  if (depth > 5) return { error: 'SCA/TAN required (interactive)' }

  // Direct result
  if (json?.Result) return { result: json }

  // Selection: bank asks which TAN method to use
  if (json?.Dialog?.input?.Selection) {
    const options = json.Dialog.input.Selection.options || []
    const ctxB64 = json.Dialog.input.Selection.context

    // Prefer push/app/decoupled option, fall back to first available
    const preferred = options.find(o => {
      const s = JSON.stringify(o ?? '').toLowerCase()
      return s.includes('push') || s.includes('app') || s.includes('decoupled')
    }) ?? options[0]

    if (!preferred) return { error: 'SCA/TAN required (interactive)' }
    console.log(`[SCA] Selection: ${options.length} option(s), auto-picking: ${JSON.stringify(preferred)}`)

    const next = service === 'balances'
      ? await client.respondBalances({ ticket, context: u8FromB64(ctxB64), response: preferred })
      : await client.respondTransactions({ ticket, context: u8FromB64(ctxB64), response: preferred })
    return handleSCAFlow(next.toJSON(), service, client, ticket, depth + 1)
  }

  // Confirmation: decoupled push-polling (~300 s)
  if (json?.Dialog?.input?.Confirmation) {
    let ctxB64 = json.Dialog.input.Confirmation.context
    let delay = json.Dialog.input.Confirmation.pollingDelaySecs || 2

    for (let i = 0; i < 60; i++) {
      await new Promise(r => setTimeout(r, Math.min(delay, 5) * 1000))
      const next = service === 'balances'
        ? await client.confirmBalances({ ticket, context: u8FromB64(ctxB64) })
        : await client.confirmTransactions({ ticket, context: u8FromB64(ctxB64) })
      const nextJson = next.toJSON()

      if (nextJson?.Result) return { result: nextJson }

      if (nextJson?.Dialog?.input?.Confirmation) {
        ctxB64 = nextJson.Dialog.input.Confirmation.context
        delay = nextJson.Dialog.input.Confirmation.pollingDelaySecs || delay
        continue
      }

      // Unexpected mid-poll interrupt (e.g. another Selection) → try outer handler
      return handleSCAFlow(nextJson, service, client, ticket, depth + 1)
    }
    return { error: 'SCA confirmation timeout' }
  }

  // Redirect: bank provides a URL — open it directly in the browser.
  if (json?.Redirect) {
    const redirectUrl = json.Redirect.url
    let ctxB64 = json.Redirect.context
    if (!ctxB64) return { error: 'SCA/TAN required (interactive)' }
    const now = Date.now()
    if (now - lastRedirectOpenedAt > 290_000) {
      console.log(`[SCA] Redirect URL — opening in browser: ${redirectUrl}`)
      exec(`open "${redirectUrl}"`)
      lastRedirectOpenedAt = now
    } else {
      console.log(`[SCA] Redirect URL — throttled (opened ${Math.round((now - lastRedirectOpenedAt) / 1000)}s ago): ${redirectUrl}`)
    }
    return handleSCARedirectPoll(ctxB64, service, client, ticket)
  }

  // RedirectHandle: no URL yet — register a redirect URI to get the bank's auth URL,
  // then open it in the browser. User logs in → bank redirects back → we poll.
  if (json?.RedirectHandle) {
    const handle = json.RedirectHandle.handle
    let ctxB64 = json.RedirectHandle.context
    if (!ctxB64) return { error: 'SCA/TAN required (interactive)' }
    console.log(`[SCA] RedirectHandle — handle: ${JSON.stringify(handle)}, registering redirect URI...`)
    try {
      // Register our Express server as the OAuth callback endpoint.
      // The bank redirects the user's browser here after approval — our route returns HTTP 200
      // so the bank considers the redirect successful and marks the consent as done.
      const bankUrl = await client.registerRedirectUri({
        ticket,
        handle,
        redirectUri: `http://localhost:${port}/simplebanking-auth-callback`
      })
      const now = Date.now()
      if (now - lastRedirectOpenedAt > 290_000) {
        console.log(`[SCA] Bank auth URL — opening in browser: ${bankUrl}`)
        exec(`open "${bankUrl}"`)
        lastRedirectOpenedAt = now
      } else {
        console.log(`[SCA] Bank auth URL — throttled (opened ${Math.round((now - lastRedirectOpenedAt) / 1000)}s ago): ${bankUrl}`)
      }
    } catch (regErr) {
      console.error(`[SCA] registerRedirectUri failed: ${regErr?.message}`)
      return { error: 'SCA/TAN required (interactive)' }
    }
    return handleSCARedirectPoll(ctxB64, service, client, ticket)
  }

  // Field or unknown dialog interrupt
  if (json?.Dialog) {
    return { error: 'SCA/TAN required (interactive)' }
  }

  return { error: 'Unknown response shape' }
}

function persistSessionArtifacts(state, sessionB64, connectionDataB64) {
  if (typeof sessionB64 === 'string' && sessionB64.length > 0) {
    inMemorySessionBase64 = sessionB64
    state.sessionBase64 = sessionB64
  } else {
    inMemorySessionBase64 = null
    state.sessionBase64 = null
  }

  if (typeof connectionDataB64 === 'string' && connectionDataB64.length > 0) {
    state.connectionDataBase64 = connectionDataB64
  }

  saveState(state)
  return {
    session: state.sessionBase64 || null,
    connectionData: state.connectionDataBase64 || null
  }
}

function issueTicket(service, data = null, ttlSeconds = 600) {
  const id = uuidv4()
  const exp = Math.floor(Date.now() / 1000) + ttlSeconds

  const payload = {
    data: {
      service,
      id,
      data
    },
    exp
  }

  const token = jwt.sign(payload, hmacKey, {
    algorithm: 'HS256',
    keyid: keyId
  })

  return { id, ticket: token, exp }
}

app.get('/health', (_req, res) => res.json({ ok: true }))

// OAuth callback from bank after user approves the redirect-based authorization.
// Bank redirects the user's browser here; we return a friendly page so the browser
// shows success instead of "site not reachable". The consent completion is signaled
// server-to-server by the bank to routex — our polling loop detects it.
app.get('/simplebanking-auth-callback', (req, res) => {
  const { code, state, error } = req.query
  console.log(`[SCA] Auth callback — code: ${code ? 'present' : 'absent'}, state: ${state ?? '-'}, error: ${error ?? '-'}`)
  lastCallbackParams = { code: code ?? null, state: state ?? null, error: error ?? null, receivedAt: Date.now() }
  const html = error
    ? `<!DOCTYPE html><html><head><meta charset="utf-8"><title>Fehler</title></head><body style="font-family:sans-serif;text-align:center;padding:60px"><h2>Fehler bei der Freigabe</h2><p>${error}</p><p>Bitte schließe dieses Fenster und versuche es erneut.</p></body></html>`
    : `<!DOCTYPE html><html><head><meta charset="utf-8"><title>Freigabe erteilt</title></head><body style="font-family:sans-serif;text-align:center;padding:60px"><h2>✓ Freigabe erteilt</h2><p>Die Banking-Verbindung wird jetzt eingerichtet.</p><p style="color:#888;font-size:14px">Du kannst dieses Fenster schließen.</p></body></html>`
  res.send(html)
})

// Issue a service ticket
app.get('/ticket', (req, res) => {
  const service = String(req.query.service || '')
  if (!service) return res.status(400).json({ ok: false, error: 'missing service' })
  const { id, ticket, exp } = issueTicket(service, null, 10 * 60)
  res.json({ ticketId: id, ticket, exp })
})

// Set IBAN (and optional currency)
app.post('/config', (req, res) => {
  const { iban, currency } = req.body || {}
  if (!iban) return res.status(400).json({ ok: false, error: 'missing iban' })
  const s = loadState()
  s.iban = iban
  s.currency = currency || 'EUR'
  s.connectionId = null
  s.connectionDisplayName = null
  s.connectionCredentialsModel = null
  s.connectionUserIdLabel = null
  s.connectionAdvice = null
  s.sessionBase64 = null
  s.connectionDataBase64 = null
  inMemorySessionBase64 = null
  saveState(s)
  res.json({ ok: true, state: s })
})

// Discover a connectionId via search (best-effort)
app.post('/discover', async (_req, res) => {
  const s = loadState()
  const client = makeClient()

  // search() needs a ticket; docs do not specify a dedicated service identifier for search.
  // Empirically, a service ticket is required; we use an Accounts ticket.
  const accountsTicket = issueTicket('Accounts', null, 10 * 60).ticket

  try {
    const connections = await client.search({
      ticket: accountsTicket,
      filters: [{ term: s.iban }],
      ibanDetection: true,
      limit: 20
    })

    const pick = connections[0]  // Use the best-ranked YAXI result for any supported bank
    if (!pick) return res.status(404).json({ ok: false, error: 'no connections found', connections: [] })

    s.connectionId = pick.id
    s.connectionDisplayName = pick.displayName
    s.connectionCredentialsModel = normalizeCredentialModel(pick.credentials)
    s.connectionUserIdLabel = normalizeOptionalText(pick.userId)
    s.connectionAdvice = normalizeOptionalText(pick.advice)
    saveState(s)

    res.json({ ok: true, picked: pick, total: connections.length })
  } catch (e) {
    res.status(500).json({ ok: false, error: String(e?.message || e), hint: 'check ticket/credentials/availability' })
  }
})

// Fetch balances.
// Body: { userId?: "...", password?: "..." } depending on connector credential model.
app.post('/balances', async (req, res) => {
  const { userId, password, session: requestSessionB64, connectionData: requestConnectionDataB64 } = req.body || {}

  const s = loadState()
  if (!s.connectionId) {
    return res.status(400).json({ ok: false, error: 'no connectionId yet', next: 'POST /discover' })
  }

  const client = makeClient()
  const ticket = issueTicket('Balances', null, 10 * 60).ticket

  const preparedCredentials = buildCredentialsForConnection(s, userId, password, requestConnectionDataB64)
  const inputValidationError = validateCredentialInput(
    preparedCredentials.model,
    preparedCredentials.normalizedUserId,
    preparedCredentials.normalizedPassword
  )
  if (inputValidationError) {
    return res.status(400).json({
      ok: false,
      error: inputValidationError,
      credentialsModel: preparedCredentials.model
    })
  }
  const credentials = preparedCredentials.credentials

  // Only set a redirect URI when no credentials are being sent (redirect-based flow).
  // Setting yaxi-redirect-uri on full-credentials requests interferes with Sparkasse's
  // direct auth path and causes Unauthorized even with correct credentials.
  const usingDirectCredentials = !!(credentials.userId || credentials.password)
  if (!usingDirectCredentials) {
    client.setRedirectUri(`http://localhost:${port}/simplebanking-auth-callback`)
  }

  const sessionB64 = preferredSessionBase64(s, requestSessionB64)
  const session = sessionB64 ? u8FromB64(sessionB64) : undefined

  try {
    lastBalancesStatus = { at: new Date().toISOString(), ok: false, stage: 'calling balances' }
    let resp
    try {
      resp = await client.balances({
        credentials,
        ticket,
        session,
        recurringConsents: true,
        accounts: [{ iban: s.iban, currency: s.currency || 'EUR' }]
      })
    } catch (firstErr) {
      const firstMsg = String(firstErr?.message || firstErr)
      const canRetryWithoutUserId =
        preparedCredentials.model.full &&
        preparedCredentials.model.userId === false &&
        !!preparedCredentials.normalizedUserId &&
        isUserIdUnsupportedError(firstMsg)

      if (!canRetryWithoutUserId) {
        throw firstErr
      }

      const fallbackCredentials = { ...credentials }
      delete fallbackCredentials.userId
      resp = await client.balances({
        credentials: fallbackCredentials,
        ticket,
        session,
        recurringConsents: true,
        accounts: [{ iban: s.iban, currency: s.currency || 'EUR' }]
      })
    }

    const json = resp.toJSON()

    async function handleResult(resultJson) {
      const [resultJwt, sessionB64, connectionDataB64] = resultJson.Result

      const decoded = decodeResultJwt(resultJwt)
      // store decoded snapshot for debugging (will not be exposed with values, only shape endpoint)
      try {
        fs.writeFileSync(path.join(process.cwd(), 'last-decoded.json'), JSON.stringify(decoded))
      } catch {}

      const sessionState = persistSessionArtifacts(s, sessionB64, connectionDataB64)

      // Extract booked/expected balances from decoded payload
      let booked = null
      let expected = null

      // YAXI docs: decoded.data.data.balances = [ { account, balances: [ ... ] } ]
      const entry = decoded?.data?.data?.balances?.[0]
      const balancesArr = entry?.balances || []
      for (const b of balancesArr) {
        if (b.balanceType === 'Booked') booked = b
        if (b.balanceType === 'Expected') expected = b
      }

      // Fallback for banks that report neither Booked nor Expected (e.g. C24 uses "Available").
      // Priority: Booked → Available → InterimBooked → ClosingBooked → first entry
      if (!booked) {
        booked = balancesArr.find(b => b.balanceType === 'Available')
          ?? balancesArr.find(b => b.balanceType === 'InterimBooked')
          ?? balancesArr.find(b => b.balanceType === 'ClosingBooked')
          ?? balancesArr[0]
          ?? null
      }

      return { ok: true, booked, expected, session: sessionState.session, connectionData: sessionState.connectionData }
    }

    // If we got a result right away
    if (json?.Result) {
      const out = await handleResult(json)
      lastBalancesStatus = { at: new Date().toISOString(), ok: out.ok, booked: out.booked ?? null, expected: out.expected ?? null }
      return res.json(out)
    }

    // SCA handling: Selection auto-pick + Confirmation polling
    const sca = await handleSCAFlow(json, 'balances', client, ticket)
    if (sca.result) {
      const out = await handleResult(sca.result)
      lastBalancesStatus = { at: new Date().toISOString(), ok: out.ok, booked: out.booked ?? null, expected: out.expected ?? null }
      return res.json(out)
    }
    lastBalancesStatus = { at: new Date().toISOString(), ok: false, error: sca.error, stage: 'sca' }
    return res.json({ ok: false, error: sca.error })
  } catch (e) {
    const msg = String(e?.message || e)
    const userMsg = (typeof e?.userMessage === 'string' && e.userMessage.length > 0) ? e.userMessage : null
    // Unauthorized = stale connectionData (invalid recurring consent). Clear it so the next
    // attempt (Swift retries automatically) goes through fresh auth without stale consent.
    if (e?.name === 'UnauthorizedException') {
      console.log('[Balances] Unauthorized — clearing stale connectionData from state')
      s.connectionDataBase64 = null
      saveState(s)
    }
    // Reset invalid session tokens.
    if (isObsoleteSessionError(msg)) {
      inMemorySessionBase64 = null
      s.sessionBase64 = null
      saveState(s)
    }
    lastBalancesStatus = { at: new Date().toISOString(), ok: false, error: msg, stage: 'exception' }
    res.status(500).json({ ok: false, error: msg, userMessage: userMsg })
  }
})

// Fetch transactions for a date range.
// Body: { userId?, password?, from?: "YYYY-MM-DD", to?: "YYYY-MM-DD" } depending on connector credential model.
app.post('/transactions', async (req, res) => {
  const { userId, password, from, to, session: requestSessionB64, connectionData: requestConnectionDataB64 } = req.body || {}

  const s = loadState()
  if (!s.connectionId) {
    return res.status(400).json({ ok: false, error: 'no connectionId yet', next: 'POST /discover' })
  }

  const client = makeClient()

  const ticketData = {
    account: { iban: s.iban, currency: s.currency || 'EUR' },
    range: {
      ...(from ? { from } : {}),
      ...(to ? { to } : {})
    }
  }

  const ticket = issueTicket('Transactions', ticketData, 10 * 60).ticket

  const preparedCredentials = buildCredentialsForConnection(s, userId, password, requestConnectionDataB64)
  const inputValidationError = validateCredentialInput(
    preparedCredentials.model,
    preparedCredentials.normalizedUserId,
    preparedCredentials.normalizedPassword
  )
  if (inputValidationError) {
    return res.status(400).json({
      ok: false,
      error: inputValidationError,
      credentialsModel: preparedCredentials.model
    })
  }
  const credentials = preparedCredentials.credentials

  const usingDirectCredentials = !!(credentials.userId || credentials.password)
  if (!usingDirectCredentials) {
    client.setRedirectUri(`http://localhost:${port}/simplebanking-auth-callback`)
  }

  const sessionB64 = preferredSessionBase64(s, requestSessionB64)
  const session = sessionB64 ? u8FromB64(sessionB64) : undefined

  async function handleResult(resultJson) {
    const [resultJwt, sessionB64, connectionDataB64] = resultJson.Result
    const decoded = decodeResultJwt(resultJwt)

    const sessionState = persistSessionArtifacts(s, sessionB64, connectionDataB64)

    // Transactions: decoded.data.data is an array of transaction objects
    const items = decoded?.data?.data
    const tx = Array.isArray(items) ? items : []

    // Format transactions for DE locale
    const formattedTx = tx.map(transaction => {
      // Format amount with comma as decimal separator
      if (transaction.transactionAmount?.amount) {
        const amount = parseFloat(transaction.transactionAmount.amount)
        transaction.transactionAmount.amount = amount.toFixed(2).replace('.', ',')
      }
      
      // Truncate recipient to 2 words
      if (transaction.creditorName) {
        const words = transaction.creditorName.split(' ')
        transaction.creditorName = words.slice(0, 2).join(' ')
      }
      if (transaction.debtorName) {
        const words = transaction.debtorName.split(' ')
        transaction.debtorName = words.slice(0, 2).join(' ')
      }
      
      return transaction
    })

    return { ok: true, transactions: formattedTx, session: sessionState.session, connectionData: sessionState.connectionData }
  }

  try {
    lastTransactionsStatus = { at: new Date().toISOString(), ok: false, stage: 'calling transactions', from: from || null, to: to || null }
    let resp
    try {
      resp = await client.transactions({
        credentials,
        ticket,
        session,
        recurringConsents: true
      })
    } catch (firstErr) {
      const firstMsg = String(firstErr?.message || firstErr)
      const canRetryWithoutUserId =
        preparedCredentials.model.full &&
        preparedCredentials.model.userId === false &&
        !!preparedCredentials.normalizedUserId &&
        isUserIdUnsupportedError(firstMsg)

      if (!canRetryWithoutUserId) {
        throw firstErr
      }

      const fallbackCredentials = { ...credentials }
      delete fallbackCredentials.userId
      resp = await client.transactions({
        credentials: fallbackCredentials,
        ticket,
        session,
        recurringConsents: true
      })
    }

    const json = resp.toJSON()

    if (json?.Result) {
      const out = await handleResult(json)
      lastTransactionsStatus = { at: new Date().toISOString(), ok: true, count: out.transactions?.length ?? 0 }
      return res.json(out)
    }

    // SCA handling: Selection auto-pick + Confirmation polling
    const sca = await handleSCAFlow(json, 'transactions', client, ticket)
    if (sca.result) {
      const out = await handleResult(sca.result)
      lastTransactionsStatus = { at: new Date().toISOString(), ok: true, count: out.transactions?.length ?? 0 }
      return res.json(out)
    }
    lastTransactionsStatus = { at: new Date().toISOString(), ok: false, error: sca.error, stage: 'sca' }
    return res.json({ ok: false, error: sca.error })
  } catch (e) {
    const msg = String(e?.message || e)
    const userMsg = (typeof e?.userMessage === 'string' && e.userMessage.length > 0) ? e.userMessage : null
    if (e?.name === 'UnauthorizedException') {
      console.log('[Transactions] Unauthorized — clearing stale connectionData from state')
      s.connectionDataBase64 = null
      saveState(s)
    }
    if (isObsoleteSessionError(msg)) {
      inMemorySessionBase64 = null
      s.sessionBase64 = null
      saveState(s)
    }
    lastTransactionsStatus = { at: new Date().toISOString(), ok: false, error: msg, stage: 'exception' }
    res.status(500).json({ ok: false, error: msg, userMessage: userMsg })
  }
})

// API endpoint for date formatting
app.get('/api/format-date', (req, res) => {
  const { date } = req.query
  if (!date) return res.status(400).json({ error: 'missing date parameter' })
  
  const today = new Date()
  const inputDate = new Date(date)
  
  // Heute
  if (inputDate.toDateString() === today.toDateString()) {
    return res.json({ formatted: 'Heute', original: date })
  }
  
  // Gestern
  const yesterday = new Date(today)
  yesterday.setDate(yesterday.getDate() - 1)
  if (inputDate.toDateString() === yesterday.toDateString()) {
    return res.json({ formatted: 'Gestern', original: date })
  }
  
  // Sonst DD.MM
  const day = inputDate.getDate().toString().padStart(2, '0')
  const month = (inputDate.getMonth() + 1).toString().padStart(2, '0')
  return res.json({ formatted: `${day}.${month}`, original: date })
})

// API endpoint for amount formatting
app.get('/api/format-amount', (req, res) => {
  const { amount } = req.query
  if (!amount) return res.status(400).json({ error: 'missing amount parameter' })
  
  const num = parseFloat(amount)
  if (isNaN(num)) return res.status(400).json({ error: 'invalid amount' })
  
  const formatted = num.toLocaleString('de-DE', { 
    minimumFractionDigits: 2, 
    maximumFractionDigits: 2 
  }) + ' €'
  
  return res.json({ formatted, original: amount })
})

app.listen(port, '127.0.0.1', () => {
  console.log(`simplebanking listening on http://127.0.0.1:${port}`)
})
