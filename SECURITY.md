# Security Policy

## Reporting a Vulnerability

Please **do not** open a public issue for security problems.

Report privately via GitHub: **Security → Report a vulnerability** on this repository
(<https://github.com/MaxHaiCom/vibe-gauge/security/advisories/new>).

Include what you found, how to reproduce it, and the version (`v1.x.x` from Releases or commit SHA).
You should get a first response within 7 days.

## Scope

Areas where a report is especially welcome:

- **API accounting proxy** (`Resources/vibegauge-proxy.py`, `127.0.0.1:18790`) — it forwards requests that carry your API keys. Anything that lets a web page, another user, or a remote host reach it, or that writes a key to disk, is in scope.
- **Process reaper** — killing a process that is not an orphaned MCP/CLI helper.
- **Shell / `ssh` invocations** built from config or file paths.

Only the latest release is supported.

---

# 安全策略

发现安全问题请**不要**开公开 issue，走本仓库 **Security → Report a vulnerability** 私密提交，7 天内回复。重点范围：记账代理（经手 API Key）、进程收割误杀、拼接 shell/ssh 命令的地方。只维护最新版本。
