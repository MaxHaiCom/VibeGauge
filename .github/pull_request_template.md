## What & why

<!-- One or two sentences. Link the issue if there is one. -->

## Checklist

- [ ] `./build.sh` succeeds and `--selftest` passes (both `-uiLanguage en` and `-uiLanguage zh`)
- [ ] `python3 Resources/vibegauge-proxy.py --selftest` passes (if the proxy changed)
- [ ] New user-visible text uses `L("中文", "English")`
- [ ] No new dependencies; new source files added to `build.sh`
- [ ] No personal data (real IPs, hostnames, paths, keys, usage numbers) in code, fixtures, screenshots, or commit messages
