# Contributing

Thanks for helping! VibeGauge is intentionally small: pure Swift + a stdlib-only Python proxy, **zero dependencies**, built with plain `swiftc` (no Xcode project).

## Build & test

```bash
ARCHS=arm64 ./build.sh          # fast local build (default builds a Universal arm64 + x86_64 app)
./VibeGauge.app/Contents/MacOS/VibeGauge --selftest -AppleLanguages '(en)'
./VibeGauge.app/Contents/MacOS/VibeGauge --selftest -AppleLanguages '(zh-Hans)'
/usr/bin/python3 Resources/vibegauge-proxy.py --selftest
open VibeGauge.app
```

CI runs the same checks on every push and PR.

## Guidelines

- **No new dependencies** (Swift packages, pip packages, …). Stdlib and system frameworks only.
- **New source file?** Add it to the file list in `build.sh`.
- **User-visible text** goes through `L("中文", "English")` so both languages stay in sync. Logs and comments may stay in either language.
- **Logic changes** should come with a `precondition` in `--selftest` (see `Sources/main.swift`) that fails if the logic breaks.
- **No personal data** in code, fixtures, screenshots, or commit messages: no real IPs, hostnames, usernames, paths, keys, or usage numbers. Use `192.0.2.x` / `198.51.100.x` (documentation ranges), `/Users/x`, and `sk-FAKE…`.
- Keep PRs focused; one change per PR.

## Reporting

- Bugs / feature ideas: [open an issue](https://github.com/MaxHaiCom/vibe-gauge/issues/new/choose).
- Security problems: **do not** open a public issue — see [SECURITY.md](SECURITY.md).

## Releasing (maintainers)

1. Bump `CFBundleShortVersionString` in `Resources/Info.plist`.
2. Commit, then `git tag vX.Y.Z && git push origin vX.Y.Z`.
3. The Release workflow refuses to publish if the tag and `Info.plist` disagree, then attaches `VibeGauge.zip` + `.sha256`. Download it once and check it opens.
