# Hatch Pet Relay Protocol v1

A tiny state relay that lets an AI agent publish its working state to a
floating desktop pet. One server, many isolated channels. Each channel holds
exactly one latest state (no history).

Public instance: `https://pet.8529527.xyz`
Self-hosting: run `app.js` (Node 18+, zero dependencies) behind any HTTPS endpoint.

## Concepts

- **Channel** — an isolated slot for one pet. Identified by a name like
  `pet-d965e4c0ce`. Created by registration; there are no user accounts.
- **Key** — the channel's only credential, a 32-character random string.
  The key *is* the identity: whoever holds it can read and write the channel.
  The server stores only the SHA-256 hash. A lost key cannot be recovered —
  register a new channel instead.
- **State** — a small JSON object (max 64 KB), replaced wholesale on each write.
  Every write increments the channel's `seq` by 1.

## Endpoints

### `GET /health`
No auth. Returns `{ "ok": true, "version": 2, "channels": <n>, "uptime_s": <n> }`.

### `POST /register`
No auth. Creates a channel. Rate-limited per source IP: 5/hour, 20/day.

Response `201`:
```json
{ "channel": "pet-d965e4c0ce", "key": "J8J0hR-…" }
```
The key is shown **once**, in this response only.

### `POST /c/<channel>` — write state
Header: `Authorization: Bearer <key>`. Body: the state JSON (see below).
Response `200`: `{ "seq": <n>, "ts": <epoch ms> }`.
Errors: `401` bad/missing key, `413` body over 64 KB, `429` rate limited.

### `GET /c/<channel>?since=<seq>` — read state
Header: `Authorization: Bearer <key>`.
- If the channel's current `seq` is greater than `since`:
  `200` with `{ "seq": <n>, "ts": <epoch ms>, "payload": <state> }`.
- Otherwise: `204 No Content` (nothing new; cheap polling).
Errors: `401`, `429`.

Rate limits for channel traffic (per IP): writes 240/min, reads 1200/min.

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

To connect a pet (or another agent) to a channel, hand over three values —
server, channel, key — as one block, e.g.:

```
server: https://pet.8529527.xyz
channel: pet-d965e4c0ce
key: <the key from /register>
```

Any client that can do HTTPS GET/POST with a bearer header can use the
protocol directly (curl, a skill, an MCP tool, a few lines of any language).
