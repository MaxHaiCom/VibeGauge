# VibeGauge data formats and interfaces

Everything VibeGauge reads or writes on disk, and every switch it accepts. Written for people building tools that feed VibeGauge, read its files, or debug it.

## Stability levels

| Level | Meaning |
|---|---|
| **Stable** | Other tools may write or read it. Fields are only ever added. A removal or meaning change bumps a version and the old form keeps being read for at least one minor release. |
| **Internal** | VibeGauge's own cache or state. It can change in any release. Don't parse it; deleting it is always safe (it is rebuilt). |

Rules for every JSON file below:

- Readers ignore unknown fields. Writers may add fields.
- A missing field means "unknown", never zero. A quota with no `used_percentage` is shown as unknown, not as 0%.
- Times are Unix epoch **seconds** (float allowed) unless a field says ISO 8601. ISO times are UTC with a `Z` suffix.
- Token counts are non-negative integers.

## Directory and permissions

All files live in `~/.config/vibegauge/` (directory mode `0700`, files `0600`). The directory is fixed for the app. The Python helpers accept `VIBEGAUGE_DIR` for tests only; if you point them elsewhere, the app will not see their output.

| File | Writer | Level |
|---|---|---|
| `api-calls.jsonl` | accounting proxy | Stable |
| `api-quota.json` | accounting proxy | Stable |
| `claude-usage.json` | statusline bridge, or your own statusline script | Stable |
| `agy-quota.json` | statusline bridge | Stable |
| `prices.json` | you | Stable |
| `plans.json` | you | Stable |
| `statusline-claude.json`, `statusline-agy.json` | statusline bridge | Internal |
| `quota-samples.json` | app | Internal |
| `usage-daily.json` | app | Internal |
| `vibegauge-proxy.py`, `vibegauge-statusline.py`, `proxy.log` | app (copied from the bundle) / proxy | Internal |

## Accounting proxy

### URL scheme

The upstream goes in the path, so no configuration is needed:

```
http://127.0.0.1:<port>/<scheme>://<host>[:port]/<path>
e.g. ANTHROPIC_BASE_URL=http://127.0.0.1:18790/https://api.anthropic.com
```

- Port: `18790` by default. Change it with `defaults write com.haifeng.vibegauge proxyPort <1024-65535>`, then reinstall the proxy from the menu. The app passes it to the proxy as `VIBEGAUGE_PROXY_PORT`.
- Only requests whose `Host` is `127.0.0.1:<port>` or `localhost:<port>` and that carry no browser headers (`Origin`, `Sec-Fetch-Site`, `Sec-Fetch-Dest`) are accepted. Anything else gets `403`.
- Responses are streamed through unchanged. Only `POST` requests are recorded.
- `GET /_vibegauge/health` returns `{"ok", "port", "uptime_s", "calls", "parsed", "errors", "hosts", "dir"}`.

### `api-calls.jsonl` (Stable)

One JSON object per line, appended. Split on `\n` only (a record may contain U+2028). A partial last line means the proxy is still writing it; skip it.

| Field | Type | Meaning |
|---|---|---|
| `ts` | ISO 8601 | Request start (UTC, second precision) |
| `epoch` | number | Request start, epoch seconds with milliseconds. Prefer this over `ts` |
| `host` | string | Upstream `host[:port]` |
| `provider` | string | Display name derived from host (and path, e.g. Volcano Engine coding vs. pay-as-you-go). Key for `plans.json` |
| `path` | string | Upstream path with the query string removed (keys can live there) |
| `model` | string | Model from the response, else from the request |
| `stream` | bool | Request asked for streaming |
| `key` | string or null | First 8 hex chars of SHA-256 of the auth header value. The key itself is never written |
| `status` | int | Upstream HTTP status; `502` when the upstream was never reached |
| `ctx` | int | **All** input tokens: fresh + cache read + cache write |
| `cache_read`, `cache_write` | int | Cached parts of `ctx` |
| `out` | int | Output tokens, **including** reasoning |
| `think` | int | Reasoning tokens (a subset of `out`) |
| `parsed` | bool | Final usage was found and fully read. When false the counts are partial or zero |
| `complete` | bool | The whole response was received |
| `sent` | bool | The request fully reached the upstream. `false` = failed before the provider saw it (DNS, refused); it did not consume plan quota |
| `ms` | int | Total duration |
| `bytes` | int | Response body bytes received |
| `rl` | object | Only rate-limit/quota response headers, lower-cased, values ≤ 80 chars. Absent if none |
| `error` | string | Present on failure, e.g. `upstream_error: TimeoutError`, `usage_not_found`, `final_usage_not_found`, `incomplete_response` |

A call counts as an **error** when `status >= 400` or `complete` is false. A missing usage block alone is not an error (embeddings, for example, have none).

Rows written before 1.1.2 lack `complete` and `sent`. Readers treat a missing `complete` as true, and a missing `sent` as true unless the row is a `502` with an `error` (the old "never reached" shape).

### `api-quota.json` (Stable)

Written atomically every 300 s (`VIBEGAUGE_QUOTA_INTERVAL`), only for providers with a known usage endpoint, using the key the proxy saw in memory. Keyed by host:

```json
{
  "open.bigmodel.cn": {
    "provider": "GLM", "captured_at": 1790000000.0,
    "kind": "quota", "plan": "Coding Pro",
    "windows": { "5h": {"used_pct": 12, "resets_at": 1790003600.0},
                 "weekly": {"used_pct": 40, "resets_at": 1790400000.0} }
  },
  "api.deepseek.com": {
    "provider": "DeepSeek", "captured_at": 1790000000.0,
    "kind": "balance", "balance": 12.5, "currency": "CNY"
  }
}
```

`kind` is `quota` (percentage windows) or `balance` (money). Any entry may carry `error` (redacted, ≤ 160 chars) instead of data.

## Statusline quota files

Claude Code and the Antigravity CLI (`agy`) pass their official quota to the statusline command on stdin. The bridge (`vibegauge-statusline.py claude|agy`) saves it and then runs your original statusline command with the same stdin.

### `claude-usage.json` (Stable)

The `rate_limits` object from Claude Code's statusline payload, unchanged, plus `_captured_at`:

```json
{
  "five_hour": {"used_percentage": 21, "resets_at": 1790003600},
  "seven_day": {"used_percentage": 52, "resets_at": 1790400000},
  "_captured_at": 1790000000.0
}
```

You can feed VibeGauge from your own statusline script by writing this file. VibeGauge also reads `~/.claude/claude-usage.json` (same shape) and uses whichever is newer; without `_captured_at` the file's modification time is used. Keys other than `five_hour` / `seven_day` that start with `five_hour_` or `seven_day_` (for example `seven_day_opus`) are shown as a secondary pool named after the suffix.

### `agy-quota.json` (Stable)

```json
{
  "pools": {
    "gemini": { "5h":     {"remaining_fraction": 0.8, "reset_at": 1790003600, "recorded_at": 1790000000.0},
                "weekly": {"remaining_fraction": 0.6, "reset_at": 1790400000, "recorded_at": 1790000000.0} },
    "3p":     { "weekly": {"remaining_fraction": 0.9, "reset_at": 1790400000, "recorded_at": 1790000000.0} }
  },
  "updated_at": 1790000000.0
}
```

agy only reports the pool of the current model, so the bridge merges into the existing file under a lock. Expired windows are kept; VibeGauge shows them as reset. VibeGauge also reads `~/.cache/agy-hud/quota_cache.json` (same shape) and takes the newer value per window.

### `statusline-<tool>.json` (Internal)

`{"original": "<your previous statusline command>", "original_statusLine": {…}}`. The command is executed by the bridge, so the bridge only trusts this file if it and its directory belong to you and are not group- or world-writable.

## User-written files

### `prices.json` (Stable)

Prices per **million** tokens. Without this file no cost is shown; there are no built-in prices. See `Resources/prices.example.json`.

```json
{ "_asof": "2026-09-18", "_currency": "USD",
  "model-name": { "in": 3.0, "cache_read": 0.3, "cache_write": 3.75, "out": 15.0 } }
```

- Keys starting with `_` are metadata. `_currency` defaults to `USD`.
- Model lookup: exact match first, then the longest key that is a prefix of the model name (case-insensitive).
- Missing `cache_read` / `cache_write` default to `in`. A row of all zeros counts as unpriced.
- Cost = `(ctx − cache_read − cache_write) × in + cache_read × cache_read + cache_write × cache_write + out × out`, divided by 1,000,000.

### `plans.json` (Stable)

Request caps for coding plans that have no usage API. VibeGauge never probes those endpoints; it divides requests counted by the proxy by your cap and labels the result "estimated". See `Resources/plans.example.json`.

```json
{ "<provider as in api-calls.jsonl>": { "plan": "Coding Plan Lite",
    "requests": { "5h": 1200, "weekly": 9000, "monthly": 18000 } } }
```

`0` or a missing window = don't estimate that window. Only calls with `sent` true are counted.

## Internal files

- `quota-samples.json`: `{"<quota>@<resets_at>": [[t, pct], …], "final2|<quota>": [[resets_at, pct]]}`. Recent quota observations for burn-rate estimates (kept 6 hours) plus the last finished cycle per quota.
- `usage-daily.json`: incremental parse state per log file plus daily totals for the Stats tab (`version` 3). Deleting it only triggers a full re-scan.

## App settings

`defaults write com.haifeng.vibegauge <key> <value>`, then restart the app (except where the panel sets it).

| Key | Default | Meaning |
|---|---|---|
| `uiLanguage` | follows system | `zh` or `en`; the switch in the panel's bottom-right corner |
| `logRetentionDays` | `30` | Session logs older than this are offered for cleanup (minimum 7) |
| `autoCleanEnabled` | off | Silently reap confirmed orphan processes |
| `proxyPort` | `18790` | Accounting proxy port (1024–65535). Reinstall the proxy after changing |
| `clashAPI` | `http://127.0.0.1:9090` | Clash / mihomo / sing-box controller for the Network tab; loopback only |
| `clashSecret` | none | Controller secret |
| `codexRemoteHost` | off | `user@host` with password-less SSH; merges Codex quota from another Mac |
| `exitChangeNotifyEnabled` | on | Notify when the AI egress IP or country changes |
| `updateCheckEnabled` | on | Check GitHub releases at most once a day |

The app also stores UI state (`vg.tab`, `vg.fiveTabsMigrated`) and update-check bookkeeping (`lastUpdateCheck`, `latestVersion`, `notifiedVersion`). Those are internal.

## Command line

| Command | Effect |
|---|---|
| `VibeGauge --selftest` | Offline deterministic tests (temp dirs, built-in fixtures). Exit 0 = pass |
| `VibeGauge --diagnose` | Prints a masked snapshot of this machine for bug reports. No assertions |
| `VibeGauge --install-proxy` / `--uninstall-proxy` | Install / remove the accounting proxy LaunchAgent |
| `python3 vibegauge-proxy.py --selftest` | Proxy self-test against a local fake upstream |
| `python3 vibegauge-statusline.py --install claude\|agy` | Take over the statusline (backs up the settings file, remembers the old command) |
| `python3 vibegauge-statusline.py --uninstall claude\|agy` | Restore the original statusline |
| `python3 vibegauge-statusline.py --selftest` | Bridge self-test in a temporary `HOME` |

## Environment variables (Python helpers)

| Variable | Default | Used by |
|---|---|---|
| `VIBEGAUGE_PROXY_PORT` | `18790` | proxy; set by the app's LaunchAgent from `proxyPort` |
| `VIBEGAUGE_DIR` | `~/.config/vibegauge` | proxy; tests only (see Directory) |
| `VIBEGAUGE_QUOTA_INTERVAL` | `300` | proxy; seconds between provider usage queries |
| `VIBEGAUGE_STATUSLINE_ACTIVE` | unset | bridge; set internally to stop a statusline command that calls back into the bridge |
