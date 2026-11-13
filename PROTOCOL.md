# Hatch Pet Relay Protocol v2

A tiny state relay that lets an AI agent publish its working state to a
floating desktop pet. One server, many isolated channels. Each channel holds
exactly one latest state (no history).

Public instance: `https://pet.8529527.xyz`
Self-hosting: the same protocol — run the relay server (Node 18+, zero
dependencies) behind any HTTPS endpoint. The channel protocol (read/write,
state payload, pairing) is identical on the public instance and on
self-hosted instances; the claim flow (`/status`, `/register`, `/redeem`)
is provided by the public instance and is optional for self-hosted ones.

What changed from v1: quota-based claiming with reservations
(`POST /register` creates a `free_` reservation that must be activated by a
first state write within 48 hours), a public read-only `GET /status`,
one-time redemption codes (`POST /redeem`, creating `tg_` channels),
a 16 KB state cap, tightened rate limits, and the pairing string format
(`hatchpet1:` + base64url JSON) replacing the v1 three-line block.

## Concepts

- **Channel** — an isolated slot for one pet. Identified by a name
  (letters, digits, `_`, `-`; max 64 chars). There are no user accounts.
  Name prefixes on the public instance indicate how the channel was claimed:
  - `free_…` — claimed directly via `/register` (counts against the free quota).
  - `tg_…` — created by redeeming a one-time code via `/redeem`; the name is
    derived deterministically from the claimant's Telegram account, so one
    Telegram account maps to exactly one channel, forever.
  - Any other name — created outside the claim flow (e.g. legacy or
    self-hosted setups); the wire protocol is the same.
- **Key** — the channel's only credential, a 32-character random string.
  The key *is* the identity: whoever holds it can read and write the channel.
  The server stores only the SHA-256 hash. A channel's key is shown **once**,
  in the response that creates the channel, and cannot be recovered if lost.
- **State** — a small JSON object (max 16 KB), replaced wholesale on each
  write. Every write increments the channel's `seq` by 1 (first write is
  `seq` 1). Reads only ever return the latest state.

## Endpoints

All error bodies are JSON: `{ "error": "<code>" }`. Common errors:
`429 { "error": "rate_limited" }`, and — when the server is overloaded
(more than 64 requests in flight) — `503 { "error": "busy" }` for every
endpoint except `/health`. Unknown paths return
`404 { "error": "not_found" }`.

### `GET /health`
No auth. Returns
`{ "ok": true, "version": 3, "channels": <n>, "free_left": <n>, "reaped": <n>, "in_flight": <n>, "uptime_s": <n> }`.

### `GET /status`
No auth, read-only. Reports the public instance's free-claim availability
(for app onboarding screens and the landing page):

```json
{ "state": "open", "free_left": 37 }
```

- `state`: `"open"` while `free_left > 0`, otherwise `"full"`.
- `free_left`: free quota total minus activated channels minus pending
  (not yet activated) reservations.
- Rate limit: the read bucket (300/min per IP).

### `POST /register` — claim a free channel (reservation)
No auth, no body. Creates a `free_` channel in the **reserved** state and
returns its key once:

Response `201`:
```json
{ "channel": "free_ab12cd34ef", "key": "J8J0hR-…" }
```

- **Reservation → activation**: the reservation holds one quota slot for
  **48 hours**. The channel's first successful state write (see below)
  activates it and consumes the slot permanently. If no state is written
  within 48 hours, the reservation expires: the channel and its key are
  deleted and the slot returns to the pool. Reading does not activate.
  Claiming agents must therefore write a first state immediately after
  claiming (see Write discipline).
- **Quota full**: `403 { "error": "quota_full", "paths": ["bot", "selfhost"] }`
  — the caller should fall back to the bot redemption flow or self-hosting.
- Rate limits: 5/hour and 20/day per IP; exceeding either returns `429`.

### `POST /redeem` — redeem a one-time code
No bearer auth; the code itself is the credential. Codes are issued out of
band (on the public instance: by the Telegram bot `@hatchPetBot` after a
task-wall check). A code is 12 characters of Crockford Base32 (no I/L/O/U),
bound to one Telegram account, and valid for **24 hours**.

Request body:
```json
{ "code": "AB12CD34EF56", "tgId": "123456789" }
```
`tgId` is the Telegram user id the code was issued to (string or number).
The code is case-insensitive (the server normalizes it to upper case).

Response `201` (key shown once; the code is consumed and deleted):
```json
{ "channel": "tg_0123456789abcdef", "key": "J8J0hR-…" }
```

Errors:
- `400 { "error": "bad_request" }` — missing/empty `code` or `tgId`,
  or an unreadable body.
- `400 { "error": "bad_json" }` — body is not valid JSON.
- `413 { "error": "too_large" }` — body over 16 KB.
- `404 { "error": "code_not_found" }` — no such code (or already redeemed).
- `403 { "error": "code_revoked" }` — the code was revoked by the operator.
- `400 { "error": "code_expired" }` — the code is past its 24-hour validity,
  or was already marked expired.
- `403 { "error": "tg_mismatch" }` — the code is bound to a different `tgId`.
- `409 { "error": "already_claimed", "channel": "tg_…" }` — this Telegram
  account already has its channel (one per account, ever). The code is
  **not** consumed in this case.
- `429 { "error": "rate_limited" }` — the write bucket (120/min per IP).

The redeemed channel is a normal channel afterwards; its first state write
activates it (it never counts against the free quota and never expires).

### `POST /c/<channel>` — write state
Header: `Authorization: Bearer <key>`. Body: the state JSON (see below).
Response `200`: `{ "seq": <n>, "ts": <epoch ms> }`.
The first successful write on a channel also activates it (see `/register`).
Errors:
- `401 { "error": "unauthorized" }` — bad/missing key, or unknown channel
  (the two are indistinguishable by design).
- `413 { "error": "too_large" }` — body over 16 KB.
- `400 { "error": "bad_json" }` — body is not valid JSON.
- `400 { "error": "bad_request" }` — body could not be read.
- `429 { "error": "rate_limited" }` — over 120 writes/min per IP.

### `GET /c/<channel>?since=<seq>` — read state
Header: `Authorization: Bearer <key>`.
- If the channel's current `seq` is greater than `since`:
  `200` with `{ "seq": <n>, "ts": <epoch ms>, "payload": <state> }`.
- Otherwise (including a channel with no writes yet): `204 No Content`
  (nothing new; cheap polling). `since` defaults to 0.
Errors: `401 { "error": "unauthorized" }`,
`429 { "error": "rate_limited" }` (over 300 reads/min per IP).
A wrong method on a `/c/…` path returns
`405 { "error": "method_not_allowed" }`.

Rate limits summary (per source IP): reads 300/min (channel reads and
`/status`), writes 120/min (channel writes and `/redeem`),
`/register` 5/hour and 20/day.

(The server also has internal admin endpoints. They are authenticated,
not part of this protocol, and are not documented here.)

## State payload

```json
{
  "state": "working",
  "event": null,
  "message": "Writing the relay protocol doc",
  "source": "claude-code"
}
```

- `state` (string, required): one of
  - `idle` — waiting for the user; nothing in progress.
  - `working` — a task is in progress (general).
  - `making` — producing an artifact (document, build, media).
  - (`sleeping` is a display-side derivation only — never write it.)
- `event` (string|null): a one-shot animation trigger; the pet plays it once,
  then falls back to `state`. One of `null`, `"waking"`, `"milestone"`.
- `message` (string, optional): a short human-readable note, ~40 characters
  max, shown as a speech bubble when the state changes.
- `source` (string, optional): which agent/client wrote this state
  (e.g. `"claude-code"`, `"hark"`). Lets several agents share one channel.
- Unknown fields are ignored by the pet but preserved by the relay.

## Write discipline (for agents)

Write at meaningful boundaries, not on a timer:

0. **Right after claiming** — a channel claimed via `/register` is only a
   reservation until its first write. Immediately after claiming (or
   redeeming), write one state (e.g. `idle` with a "connected" `message`)
   to activate the channel; an unactivated `free_` reservation is deleted
   after 48 hours.
1. **Task start** — `working` (or `making` when producing an artifact),
   with a `message` naming the task.
2. **Milestone** — a phase completed: `event: "milestone"`, current `state`,
   `message` summarizing what landed.
3. **Waiting on the user** — `idle`, `message` stating exactly what is needed.
4. **Task done** — `idle`, `message` with the outcome.
5. Session/agent start may send `event: "waking"` once.

Throttle: at most one write per few seconds; don't rewrite an unchanged
state (the `seq` only advances on real writes, and pets animate on change).

## Pairing

To connect a pet (or another agent) to a channel, hand over a single
**pairing string**:

```
hatchpet1:<base64url>
```

The part after the `hatchpet1:` prefix is the base64url encoding
(RFC 4648 §5, padding optional) of a UTF-8 JSON object:

```json
{ "v": 1, "server": "https://pet.8529527.xyz", "channel": "free_ab12cd34ef", "key": "J8J0hR-…" }
```

Decoding and validation rules for clients:

1. Trim surrounding whitespace. The string must start with the literal,
   case-sensitive prefix `hatchpet1:` — reject it otherwise.
2. Base64url-decode the remainder and parse it as JSON. If decoding or
   parsing fails, reject the whole string; never apply a partial result.
3. The JSON must be an object with `v` equal to the number `1`,
   `server` a non-empty string (the relay base URL, `https:`),
   `channel` matching `[A-Za-z0-9_-]{1,64}`, and `key` a non-empty string.
   Unknown extra fields are ignored (forward compatibility within v1).
4. On success, store the key like a credential (OS keychain or equivalent)
   and discard the raw pairing string.

Security notes: base64 is an encoding, **not** encryption — a pairing string
is exactly as sensitive as the key itself. Never post it publicly, never
log it, and only hand it to the pet app or agent it is meant for. (Manual
entry of the three fields — server, channel, key — remains available in
client settings as a fallback, but the pairing string is the canonical
interchange format. The v1 three-line text block is superseded.)

Any client that can do HTTPS GET/POST with a bearer header can use the
protocol directly (curl, a skill, an MCP tool, a few lines of any language).
