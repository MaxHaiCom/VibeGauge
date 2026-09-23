# Contributing

Thanks for helping! VibeGauge is intentionally small: pure Swift + a stdlib-only Python proxy, **zero dependencies**, built with plain `swiftc` (no Xcode project).

## Build & test

```bash
ARCHS=arm64 ./build.sh          # fast local build (default builds a Universal arm64 + x86_64 app)
./VibeGauge.app/Contents/MacOS/VibeGauge --selftest -uiLanguage en
./VibeGauge.app/Contents/MacOS/VibeGauge --selftest -uiLanguage zh
/usr/bin/python3 Resources/vibegauge-proxy.py --selftest
/usr/bin/python3 Resources/vibegauge-statusline.py --selftest
open VibeGauge.app
```

CI runs the same checks on every push and PR.

## Code map

| Area | Files |
|---|---|
| Scan loop and caches | `ProcessScanner.swift` (the class and all its stored state), `Platforms.swift` (one card per AI tool) |
| Processes | `ProcessTable.swift` (read-only: sessions, services, redaction) · `Reaper.swift` (**destructive**: kill orphans, clear npx cache) |
| Data sources | `QuotaSources.swift` (Claude / Codex / Grok / Gemini quotas and tiers) · `TokenUsage.swift` (session logs, today's usage) · `APIUsage.swift` (accounting proxy files, prices, rate-limit headers) · `UsageHistory.swift` (daily history cache) · `DiskInventory.swift` |
| Forecast | `QuotaForecast.swift` (`QuotaWindow`, `Burn`, `ActivityProfile`, quota sampling) · `Pressure.swift` (menu-bar icon signal) |
| Shared | `Models.swift`, `Formatting.swift` (`Fmt`), `Localization.swift` (`L()`) |
| Network | `NetworkScanner.swift`, `NetworkTabView.swift` |
| UI and app | `DashboardView.swift`, `StatsTabView.swift`, `AppDelegate.swift`, `ProxyManager.swift`, `UpdateChecker.swift`, `main.swift` |
| Tests | `SelfTest.swift` (`--selftest`), `SelfTestFixtures.swift`, `Diagnostics.swift` (`--diagnose`) |
| Data formats | `docs/PROTOCOL.md`: every file, field, setting, and flag. Update it when you add or change one |
| Python helpers | `Resources/vibegauge-proxy.py` (accounting proxy), `Resources/vibegauge-statusline.py` (statusline bridge) |

## Guidelines

- **No new dependencies** (Swift packages, pip packages, …). Stdlib and system frameworks only.
- **New source file?** Just drop it in `Sources/`; `build.sh` compiles `Sources/*.swift`.
- **User-visible text** goes through `L("中文", "English")` so both languages stay in sync. Logs and comments may stay in either language.
- **UI changes**: regenerate the README screenshots with `tools/screenshots.sh` (renders made-up demo data offscreen; never reads your real usage).
- **Logic changes** should come with a `precondition` in `--selftest` (see `Sources/SelfTest.swift`; real-format log samples per upstream CLI version live in `Sources/SelfTestFixtures.swift`) that fails if the logic breaks.
- **No personal data** in code, fixtures, screenshots, or commit messages: no real IPs, hostnames, usernames, paths, keys, or usage numbers. Use `192.0.2.x` / `198.51.100.x` (documentation ranges), `/Users/x`, and `sk-FAKE…`.
- Keep PRs focused; one change per PR.

## Reporting

- Bugs / feature ideas: [open an issue](https://github.com/MaxHaiCom/vibe-gauge/issues/new/choose).
- Security problems: **do not** open a public issue — see [SECURITY.md](SECURITY.md).

## Releasing (maintainers)

1. Bump `CFBundleShortVersionString` in `Resources/Info.plist`.
2. Commit, then `git tag vX.Y.Z && git push origin vX.Y.Z`.
3. The Release workflow refuses to publish if the tag and `Info.plist` disagree, then attaches `VibeGauge.zip` + `.sha256`. Download it once and check it opens.
