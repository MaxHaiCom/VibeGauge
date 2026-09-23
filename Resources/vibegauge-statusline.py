#!/usr/bin/env python3
"""VibeGauge 状态栏桥接（纯标准库，不碰任何凭据，不发任何网络请求）。

Claude Code / Antigravity CLI (agy) 每次刷新状态栏，都会把官方下发的额度（5h / 周已用、重置时刻）
通过 stdin 交给状态栏命令。本脚本截下一份写到 ~/.config/vibegauge/，再把同一份 stdin 原样交给
用户原来的状态栏命令 —— 用户看到的状态栏不变；原来没配状态栏的，显示一行简短额度。

  vibegauge-statusline.py claude|agy              作为状态栏命令运行
  vibegauge-statusline.py --install claude|agy    接管状态栏（先备份配置文件，记下原命令）
  vibegauge-statusline.py --uninstall claude|agy  还原成原来的状态栏
  vibegauge-statusline.py --install-hooks claude    写入「待处理会话」Hook（合并进 settings.json 的 hooks，先备份）
  vibegauge-statusline.py --uninstall-hooks claude  只删自己的 Hook 条目
  vibegauge-statusline.py --hook claude             作为 Hook 命令运行（只记事件类型 / 时间 / 会话 ID，永不输出）
  vibegauge-statusline.py --selftest
"""
import fcntl
import json
import os
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

MARK = "vibegauge-statusline.py"
REENTRY = "VIBEGAUGE_STATUSLINE_ACTIVE"   # 原命令经包装脚本又调回本脚本时，靠这个环境变量认出来，不再往下转


def data_dir() -> str:
    return os.path.join(os.path.expanduser("~"), ".config", "vibegauge")


def settings_path(tool: str) -> str:
    home = os.path.expanduser("~")
    return {"claude": os.path.join(home, ".claude", "settings.json"),
            "agy": os.path.join(home, ".gemini", "antigravity-cli", "settings.json")}[tool]


def out_path(tool: str) -> str:
    return os.path.join(data_dir(), {"claude": "claude-usage.json", "agy": "agy-quota.json"}[tool])


def sessions_path() -> str:
    """Claude 各会话的上下文水位（只存数字、模型 ID、工作目录和时间，不存正文）"""
    return os.path.join(data_dir(), "claude-sessions.json")


def state_path(tool: str) -> str:
    """每个工具一个状态文件：同时连接 Claude 和 agy 时不会互相覆盖对方的「原命令」记录"""
    return os.path.join(data_dir(), "statusline-%s.json" % tool)


def private_dir() -> str:
    """~/.config/vibegauge 必须只有自己能写：状态文件里的原命令会被当 shell 命令执行"""
    d = data_dir()
    os.makedirs(d, mode=0o700, exist_ok=True)
    os.chmod(d, 0o700)
    return d


def trusted(path: str) -> bool:
    """文件及其目录属于当前用户且别人不可写，才信任里面的内容"""
    try:
        for p in (path, os.path.dirname(path)):
            st = os.stat(p)
            if st.st_uid != os.getuid() or st.st_mode & 0o022:
                return False
        return True
    except OSError:
        return False


def script_path() -> str:
    return os.path.join(data_dir(), MARK)


def read_json(path: str, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path: str, obj, mode: int = 0o600, indent=None) -> None:
    """先写临时文件再原子替换：状态栏每秒可能跑好几次，不能让读的一方读到半个文件。
    写到软链接指向的真实文件：不少人用 dotfiles 仓库管 settings.json，替换掉软链接本身会断了他们的链接。"""
    path = os.path.realpath(path)
    d = os.path.dirname(path)
    os.makedirs(d, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".vg-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(obj, f, ensure_ascii=False, indent=indent)
            if indent:
                f.write("\n")
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


# ---------------------------------------------------------------- 截额度

def capture(tool: str, data, now: float) -> None:
    if not isinstance(data, dict):
        return
    if tool == "claude":
        rl = data.get("rate_limits")          # {"five_hour": {"used_percentage", "resets_at"}, "seven_day": {...}}
        if isinstance(rl, dict) and rl:
            private_dir()
            write_json(out_path(tool), dict(rl, _captured_at=now))
        save_claude_session(data, now)
        return
    # agy：{"quota": {"gemini-5h": {"remaining_fraction", "reset_in_seconds"}, "3p-weekly": {...}}}
    # 只带当前模型所在的池，所以要跟旧文件合并；过期条目也留着（VibeGauge 自己判断已重置 → 0%）
    q = data.get("quota") or data.get("quotas")
    if not isinstance(q, dict) or not q:
        return
    model = data.get("model")
    mid = str(model.get("id") if isinstance(model, dict) else model or "").lower()
    default_pool = "3p" if any(k in mid for k in ("claude", "gpt", "3p")) else "gemini"
    # 多个 agy 会话同时刷新：读-合并-写整段加锁，不然后写的会把先写的那个池覆盖掉
    with open(os.path.join(private_dir(), ".agy-quota.lock"), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        merge_agy(q, default_pool, now)


SESSIONS_KEEP = 24 * 3600
SESSIONS_MAX = 50


def save_claude_session(data: dict, now: float) -> None:
    """按 session_id 记上下文水位：context_window.used_percentage 只算输入（含缓存），/compact 后到下次请求前可能为 null"""
    sid, cw = data.get("session_id"), data.get("context_window")
    if not isinstance(sid, str) or not sid or not isinstance(cw, dict):
        return
    def num(v):
        return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None
    model, ws = data.get("model"), data.get("workspace")
    row = {"used_pct": num(cw.get("used_percentage")), "window": num(cw.get("context_window_size")),
           "model": (model.get("id") or model.get("display_name")) if isinstance(model, dict) else (model if isinstance(model, str) else None),
           "cwd": ws.get("current_dir") if isinstance(ws, dict) else data.get("cwd"),
           "transcript": data.get("transcript_path") if isinstance(data.get("transcript_path"), str) else None, "at": now}
    # 多个会话同时刷新：读-合并-写整段加锁
    with open(os.path.join(private_dir(), ".claude-sessions.lock"), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        cache = read_json(sessions_path(), {})
        sessions = cache.get("sessions") if isinstance(cache.get("sessions"), dict) else {}
        sessions[sid] = row
        # 坏条目（at 不是数字）直接丢，别让它挡住后面所有会话的更新
        fresh = {k: v for k, v in sessions.items() if isinstance(v, dict) and (num(v.get("at")) or 0) > now - SESSIONS_KEEP}
        keep = dict(sorted(fresh.items(), key=lambda kv: kv[1]["at"], reverse=True)[:SESSIONS_MAX])
        write_json(sessions_path(), {"sessions": keep, "updated_at": now})


def merge_agy(q: dict, default_pool: str, now: float) -> None:
    tool = "agy"
    cache = read_json(out_path(tool), {})
    pools = cache.get("pools") if isinstance(cache.get("pools"), dict) else {}
    for key, v in q.items():
        if not isinstance(v, dict):
            continue
        k = key.lower()
        pool = "3p" if k.startswith("3p") else "gemini" if k.startswith("gemini") else default_pool
        win = "5h" if ("5h" in k or "five" in k) else "weekly" if ("week" in k or "7d" in k) else None
        rf = v.get("remaining_fraction")
        if rf is None and v.get("used_percentage") is not None:
            rf = 1 - float(v["used_percentage"]) / 100
        if win is None or rf is None:
            continue
        reset = v.get("reset_at")
        if not isinstance(reset, (int, float)):
            secs = v.get("reset_in_seconds")
            reset = now + float(secs) if isinstance(secs, (int, float)) else None
        pools.setdefault(pool, {})[win] = {"remaining_fraction": max(0.0, min(1.0, float(rf))),
                                           "reset_at": reset, "recorded_at": now}
    write_json(out_path(tool), {"pools": pools, "updated_at": now})


def short_line(tool: str, data) -> str:
    """用户原来没配状态栏时显示的一行：5h 21% · 周 52%"""
    parts = []
    if tool == "claude" and isinstance(data, dict) and isinstance(data.get("rate_limits"), dict):
        for key, label in (("five_hour", "5h"), ("seven_day", "7d")):
            w = data["rate_limits"].get(key)
            if isinstance(w, dict) and w.get("used_percentage") is not None:
                parts.append("%s %d%%" % (label, round(float(w["used_percentage"]))))
    elif tool == "agy":
        pools = read_json(out_path(tool), {}).get("pools", {})
        for pool in ("gemini", "3p"):
            for win, label in (("5h", "5h"), ("weekly", "7d")):
                w = pools.get(pool, {}).get(win)
                if w and (w.get("reset_at") or 0) > time.time():
                    parts.append("%s%s %d%%" % ("3p " if pool == "3p" else "", label,
                                                round((1 - w["remaining_fraction"]) * 100)))
    return " · ".join(parts)


def run(tool: str) -> None:
    # 全程按字节：状态栏进程的区域设置未必是 UTF-8，按文本读遇到中文路径会直接抛错，整个状态栏变空
    raw = sys.stdin.buffer.read()
    data = None
    try:
        data = json.loads(raw.decode("utf-8", errors="replace")) if raw.strip() else None
        capture(tool, data, time.time())
    except Exception:
        pass                                   # 状态栏绝不能因为截额度失败而挂掉
    sp = state_path(tool)
    orig = read_json(sp, {}).get("original") if trusted(sp) else None
    # 防套娃：命令里直接写着自己，或经包装脚本绕回来（环境变量还在）
    if orig and MARK not in orig and not os.environ.get(REENTRY):
        sys.stdout.buffer.write(run_original(orig, raw))
    else:
        sys.stdout.buffer.write((short_line(tool, data) + "\n").encode("utf-8"))


def run_original(cmd: str, raw: bytes, timeout: float = 10) -> bytes:
    """在独立进程组里跑用户原来的状态栏命令：超时整组杀掉，管道里挂住的子进程不会越积越多"""
    try:
        p = subprocess.Popen(cmd, shell=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, start_new_session=True, env=dict(os.environ, **{REENTRY: "1"}))
    except OSError:
        return b""
    try:
        out, _ = p.communicate(raw, timeout=timeout)
        return out
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        p.communicate()
        return b""


# ---------------------------------------------------------------- 接管 / 还原

def load_settings(path: str) -> dict:
    """配置文件不存在 → 空；存在但不是合法 JSON → 报错退出，绝不覆盖用户手写的内容"""
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as f:
        obj = json.load(f)
    if not isinstance(obj, dict):
        raise ValueError("settings is not a JSON object")
    return obj


def save_settings(path: str, obj: dict) -> None:
    mode = os.stat(path).st_mode & 0o777 if os.path.exists(path) else 0o644
    write_json(path, obj, mode=mode, indent=2)


def read_bytes(path: str):
    try:
        with open(path, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return None


def edit_settings(path: str, change):
    """读 → 改 → 写回前再读一遍：期间 CLI 或编辑器改过这个文件，就基于新内容重来，不拿旧快照覆盖别人的修改。
    change(settings, raw) 返回 (新 settings 或 None=不用写, 结果)。"""
    for _ in range(5):
        raw = read_bytes(path)
        new, result = change(load_settings(path), raw)
        if new is None:
            return result
        if read_bytes(path) != raw:
            continue
        save_settings(path, new)
        return result
    raise OSError("settings.json keeps changing, try again")


def statusline_of(settings: dict):
    sl = settings.get("statusLine")
    return sl if isinstance(sl, dict) else None


def install(tool: str) -> str:
    path = settings_path(tool)

    bpath = path + ".vibegauge-backup"

    def change(settings, raw):
        sl = statusline_of(settings)
        if sl and MARK in str(sl.get("command", "")):
            # 已连接：顺手把旧版本留下的 0644 备份收紧
            if os.path.isfile(bpath) and not os.path.islink(bpath):
                os.chmod(bpath, 0o600)
            return None, "already"
        if raw is not None:
            # settings.json 里可能有 env 凭据：备份一律 0600。先删旧文件再以 0600 新建 ——
            # 不跟随软链接，也没有「先写内容后改权限」的窗口
            if os.path.lexists(bpath):
                os.unlink(bpath)
            fd = os.open(bpath, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "wb") as f:
                f.write(raw)
        private_dir()
        write_json(state_path(tool), {"original": sl.get("command") if sl else None, "original_statusLine": sl})
        new = dict(sl or {})
        new.update({"type": "command", "command": "/usr/bin/python3 %s %s" % (shlex.quote(script_path()), tool)})
        return dict(settings, statusLine=new), "installed"

    return edit_settings(path, change)


def uninstall(tool: str) -> str:
    path = settings_path(tool)
    saved = read_json(state_path(tool), None)
    if not isinstance(saved, dict):
        # 状态记录丢了：从接管时的备份里找原来的 statusLine，别当成「原来没有」直接删
        backup = read_json(path + ".vibegauge-backup", {})
        bsl = statusline_of(backup) if isinstance(backup, dict) else None
        saved = {"original_statusLine": bsl if bsl and MARK not in str(bsl.get("command", "")) else None}

    def change(settings, raw):
        sl = statusline_of(settings)
        if not (sl and MARK in str(sl.get("command", ""))):
            return None, "not-installed"       # 用户已经手动改掉了，不动他的配置
        new = dict(settings)
        if saved.get("original_statusLine"):
            new["statusLine"] = saved["original_statusLine"]
        else:
            new.pop("statusLine", None)
        return new, "uninstalled"

    result = edit_settings(path, change)
    if os.path.exists(state_path(tool)):
        os.remove(state_path(tool))
    return result


# ---------------------------------------------------------------- 待处理会话（Claude Code Hook）
# 只观察，不替你批准：PermissionRequest 的 Hook 往 stdout 写 JSON 就等于代你答复，所以这里永远不输出任何东西。
# 只记事件类型、时间、会话 ID、工作目录、工具名；不记命令内容和消息正文。
HOOK_FLAG = "--hook"
HOOK_EVENTS = ["PermissionRequest", "Notification", "PostToolUse", "PostToolUseFailure", "PermissionDenied",
               "SubagentStop", "UserPromptSubmit", "Stop", "SessionEnd"]
CALL_DONE_EVENTS = {"PostToolUse", "PostToolUseFailure", "PermissionDenied"}   # 这一次工具调用有了结果
SESSION_CLEAR_EVENTS = {"UserPromptSubmit", "Stop", "SessionEnd"}              # 整个会话往下走了
WAITING_KEEP = 24 * 3600
DONE_KEEP = 600                                  # 已结束调用的墓碑：迟到的 PermissionRequest 不能把它复活


def waiting_path() -> str:
    return os.path.join(data_dir(), "claude-waiting.json")


def hook_command(tool: str) -> str:
    return "/usr/bin/python3 %s %s %s" % (shlex.quote(script_path()), HOOK_FLAG, tool)


def is_our_hook(h) -> bool:
    """只认本工具装的那条命令（完整参数逐个比对）；用户自己写的、碰巧含这些字样的命令不算"""
    if not isinstance(h, dict) or not isinstance(h.get("command"), str):
        return False
    try:
        argv = shlex.split(h["command"])
    except ValueError:
        return False
    return len(argv) == 4 and argv[0] == "/usr/bin/python3" and argv[1] == script_path() and argv[2] == HOOK_FLAG


def _events_with_our_hook(settings: dict) -> set:
    hooks = settings.get("hooks") if isinstance(settings.get("hooks"), dict) else {}
    return {ev for ev, groups in hooks.items() if isinstance(groups, list)
            for g in groups if isinstance(g, dict) and isinstance(g.get("hooks"), list) and "matcher" not in g
            for h in g["hooks"] if is_our_hook(h)}


def hooks_installed(settings: dict) -> bool:
    return bool(_events_with_our_hook(settings))


def install_hooks(tool: str) -> str:
    path = settings_path(tool)
    bpath = path + ".vibegauge-hooks-backup"
    def change(settings, raw):
        missing = [ev for ev in HOOK_EVENTS if ev not in _events_with_our_hook(settings)]   # 逐事件补齐，缺哪个补哪个
        if not missing:
            return None, "already"
        if raw is not None and not hooks_installed(settings):   # 同状态栏：备份 0600，不跟随软链接；只备份装之前的原样
            if os.path.lexists(bpath):
                os.unlink(bpath)
            fd = os.open(bpath, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "wb") as f:
                f.write(raw)
        private_dir()
        hooks = dict(settings.get("hooks")) if isinstance(settings.get("hooks"), dict) else {}
        for ev in missing:
            groups = list(hooks.get(ev)) if isinstance(hooks.get(ev), list) else []
            groups.append({"hooks": [{"type": "command", "command": hook_command(tool), "timeout": 5}]})
            hooks[ev] = groups
        return dict(settings, hooks=hooks), "installed"
    return edit_settings(path, change)


def uninstall_hooks(tool: str) -> str:
    path = settings_path(tool)
    def change(settings, raw):
        if not hooks_installed(settings):
            return None, "not-installed"
        hooks = {}
        for ev, groups in settings["hooks"].items():
            if not isinstance(groups, list):
                hooks[ev] = groups
                continue
            kept, removed = [], False
            for g in groups:
                if isinstance(g, dict) and isinstance(g.get("hooks"), list):
                    rest = [h for h in g["hooks"] if not is_our_hook(h)]
                    removed = removed or len(rest) != len(g["hooks"])
                    if rest or not g["hooks"]:
                        kept.append(dict(g, hooks=rest) if rest else g)
                else:
                    kept.append(g)
            if kept or not removed:              # 用户原本就有的空数组原样留着；只删因为拿掉我们的条目才空掉的事件
                hooks[ev] = kept
        new = dict(settings)
        if hooks:
            new["hooks"] = hooks
        else:
            new.pop("hooks", None)
        return new, "uninstalled"
    return edit_settings(path, change)


def _num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def record_hook(data, now: float) -> None:
    """每个会话：calls = 按「子代理|工具调用 ID」分开的待批准调用（pending → 收到 Claude 自己的 permission_prompt 通知后 permission），
    input = 在等你输入。只有确认过的才会被界面显示。"""
    if not isinstance(data, dict):
        return
    sid, ev = data.get("session_id"), data.get("hook_event_name")
    if not isinstance(sid, str) or not sid or not isinstance(ev, str):
        return
    ntype = data.get("notification_type")
    input_note = ev == "Notification" and ntype in ("idle_prompt", "elicitation_dialog", "elicitation_url_dialog")
    if ev not in ("PermissionRequest", "SubagentStop") and ev not in CALL_DONE_EVENTS and ev not in SESSION_CLEAR_EVENTS \
            and not (ev == "Notification" and (ntype == "permission_prompt" or input_note)):
        return
    agent = data.get("agent_id") if isinstance(data.get("agent_id"), str) else ""
    use_id = data.get("tool_use_id") if isinstance(data.get("tool_use_id"), str) else ""
    key = agent + "|" + use_id
    path = waiting_path()
    creates = ev == "PermissionRequest" or input_note or (ev == "Notification" and ntype == "permission_prompt")
    # 存在性检查也在锁里做：锁外先读会和正在写的通知撞车，丢掉这次清除
    with open(os.path.join(private_dir(), ".claude-waiting.lock"), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not creates and not os.path.exists(path):
            return
        cache = read_json(path, {})
        sessions = cache.get("sessions") if isinstance(cache.get("sessions"), dict) else {}
        sess = sessions.get(sid) if isinstance(sessions.get(sid), dict) else None
        if sess is None and not creates:
            return                               # 清除事件每次工具调用都来：没记着这个会话就不写文件
        sess = dict(sess or {})
        calls = {k: v for k, v in (sess.get("calls") or {}).items() if isinstance(v, dict) and _num(v.get("since")) is not None}
        done = {k: t for k, t in (sess.get("done") or {}).items() if _num(t) is not None and t > now - DONE_KEEP}
        if ev in SESSION_CLEAR_EVENTS:
            sessions.pop(sid, None)
            sess = None
        else:
            if ev == "PermissionRequest":
                if use_id and key in done:
                    return                       # 这次调用已经有结果了，迟到的请求不算
                old = calls.get(key, {})
                calls[key] = {"state": old.get("state", "pending"), "since": old.get("since", now),
                              "tool": data.get("tool_name") if isinstance(data.get("tool_name"), str) else None}
            elif ev == "Notification" and ntype == "permission_prompt":
                for c in calls.values():         # 通知不带调用 ID：之前发起的待批准调用都算确认
                    c["state"] = "permission"
                if not calls:                    # 没有对应的 PermissionRequest（如沙箱联网批准）：单独记一条
                    calls["|notify"] = {"state": "permission", "since": now, "tool": None}
            elif input_note:
                sess["input"] = sess.get("input") if _num(sess.get("input")) is not None else now
            elif ev == "SubagentStop":
                calls = {k: v for k, v in calls.items() if not (agent and k.startswith(agent + "|"))}
            else:                                # 这次调用有了结果：只清对应那一个；不带调用 ID 时清这个子代理的全部
                # PermissionRequest 可能不带调用 ID（存成「子代理|」）：同一子代理没 ID 的请求、以及独立通知，一并视为有了结果
                prefix = agent + "|"
                if use_id:
                    calls.pop(key, None)
                    done[key] = now
                    calls = {k: v for k, v in calls.items() if k not in (prefix, prefix + "notify")}
                else:
                    calls = {k: v for k, v in calls.items() if not k.startswith(prefix)}
                if not agent:
                    sess.pop("input", None)
            sess.update(calls=calls, done=done, at=now)
            for k in ("cwd", "transcript_path"):
                if isinstance(data.get(k), str):
                    sess[k] = data[k]
            if calls or done or "input" in sess:  # 墓碑也要留着（十分钟后自然过期）
                sessions[sid] = sess
            else:
                sessions.pop(sid, None)
        sessions = {k: v for k, v in sessions.items() if isinstance(v, dict) and (_num(v.get("at")) or 0) > now - WAITING_KEEP}
        write_json(path, {"sessions": sessions, "updated_at": now})


def run_hook() -> None:
    try:
        raw = sys.stdin.buffer.read()
        record_hook(json.loads(raw.decode("utf-8", errors="replace")) if raw.strip() else None, time.time())
    except Exception:
        pass                                       # Hook 出错绝不能影响会话；也绝不输出


# ---------------------------------------------------------------- 自测

def selftest() -> None:
    real_home = os.environ.get("HOME")
    tmp = tempfile.mkdtemp(prefix="vg-statusline-")
    os.environ["HOME"] = tmp
    try:
        me = os.path.abspath(__file__)
        os.makedirs(data_dir())
        shutil.copy2(me, script_path())

        def run_as_statusline(tool: str, payload) -> str:
            env = dict(os.environ, HOME=tmp)
            return subprocess.run([sys.executable, script_path(), tool], input=json.dumps(payload),
                                  capture_output=True, text=True, env=env, timeout=20).stdout

        # 1. 有原状态栏：接管后原命令照常收到同一份 stdin，显示不变
        cpath = settings_path("claude")
        os.makedirs(os.path.dirname(cpath))
        orig = {"type": "command", "command": "python3 -c 'import sys,json; print(\"ORIG\", json.load(sys.stdin)[\"model\"])'",
                "padding": 1}
        write_json(cpath, {"theme": "dark", "statusLine": orig, "zeta": 1}, mode=0o644, indent=2)
        assert install("claude") == "installed" and install("claude") == "already"
        s = load_settings(cpath)
        assert MARK in s["statusLine"]["command"] and s["statusLine"]["padding"] == 1
        assert list(s.keys()) == ["theme", "statusLine", "zeta"], "别打乱用户配置的键顺序"
        assert os.stat(cpath + ".vibegauge-backup").st_mode & 0o777 == 0o600, "原文件 0644 的备份也要收成 0600"
        os.chmod(cpath + ".vibegauge-backup", 0o644)            # 模拟旧版本留下的宽权限备份
        assert install("claude") == "already" and os.stat(cpath + ".vibegauge-backup").st_mode & 0o777 == 0o600
        payload = {"model": "opus", "rate_limits": {"five_hour": {"used_percentage": 21, "resets_at": 1790092800},
                                                    "seven_day": {"used_percentage": 52, "resets_at": 1790456400}}}
        assert run_as_statusline("claude", payload).strip() == "ORIG opus"
        u = read_json(out_path("claude"), {})
        assert u["five_hour"]["used_percentage"] == 21 and u["_captured_at"] > 0
        assert os.stat(out_path("claude")).st_mode & 0o777 == 0o600
        # 会话上下文水位：按 session_id 各存一份，只存数字；/compact 后 used_percentage 为 null 也照记（界面显示未知）
        for sid, pct in (("s-a", 72.5), ("s-b", None)):
            run_as_statusline("claude", {"session_id": sid, "model": {"id": "claude-opus-5", "display_name": "Opus"},
                                         "workspace": {"current_dir": "/Users/x/p"},
                                         "context_window": {"used_percentage": pct, "context_window_size": 1000000,
                                                            "current_usage": None}})
        ss = read_json(sessions_path(), {})["sessions"]
        assert ss["s-a"]["used_pct"] == 72.5 and ss["s-a"]["window"] == 1000000 and ss["s-a"]["model"] == "claude-opus-5", ss
        assert ss["s-b"]["used_pct"] is None and ss["s-a"]["cwd"] == "/Users/x/p"
        assert os.stat(sessions_path()).st_mode & 0o777 == 0o600
        # 24 小时前的会话清掉
        stale = read_json(sessions_path(), {}); stale["sessions"]["old"] = {"used_pct": 1, "at": time.time() - 2 * 86400}
        stale["sessions"]["bad"] = {"at": "yesterday"}
        write_json(sessions_path(), stale)
        run_as_statusline("claude", {"session_id": "s-a", "context_window": {"used_percentage": 80}})
        assert "old" not in read_json(sessions_path(), {})["sessions"] and "bad" not in read_json(sessions_path(), {})["sessions"]
        # 待处理会话 Hook：合并进已有 hooks，不动别人的；卸载只删自己的
        s0 = load_settings(cpath)
        s0["hooks"] = {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo user-hook"}]}],
                       "Stop": [{"hooks": [{"type": "command", "command": "echo user-stop"}]}]}
        write_json(cpath, s0, indent=2)
        s0["hooks"]["Notification"] = [{"hooks": [{"type": "command", "command": "echo vibegauge-statusline.py --hook"}]}]
        s0["hooks"]["PostToolBatch"] = []
        write_json(cpath, s0, indent=2)
        assert not hooks_installed(s0), "用户自己的命令碰巧含这些字样，不算我们的"
        assert install_hooks("claude") == "installed" and install_hooks("claude") == "already"
        # 只剩一个事件的 Hook（被用户删了一部分）：再装要补齐，不是 already
        part = load_settings(cpath); part["hooks"]["Stop"] = [g for g in part["hooks"]["Stop"] if not any(is_our_hook(x) for x in g["hooks"])]
        write_json(cpath, part, indent=2)
        assert install_hooks("claude") == "installed" and install_hooks("claude") == "already"
        h = load_settings(cpath)["hooks"]
        assert set(HOOK_EVENTS) <= set(h) and h["PreToolUse"][0]["hooks"][0]["command"] == "echo user-hook", h
        assert h["Stop"][0]["hooks"][0]["command"] == "echo user-stop" and is_our_hook(h["Stop"][1]["hooks"][0])
        assert h["Stop"][1]["hooks"][0]["timeout"] == 5 and "matcher" not in h["Stop"][1]
        assert os.stat(cpath + ".vibegauge-hooks-backup").st_mode & 0o777 == 0o600
        def hook(payload):
            r = subprocess.run([sys.executable, script_path(), HOOK_FLAG, "claude"], input=json.dumps(payload),
                               capture_output=True, text=True, env=dict(os.environ, HOME=tmp), timeout=20)
            assert r.returncode == 0 and r.stdout == "", ("Hook 必须零输出（否则等于替用户答复权限）", r.stdout)
        def waiting():
            return read_json(waiting_path(), {}).get("sessions", {})
        hook({"session_id": "w1", "hook_event_name": "PostToolUse", "tool_name": "Bash"})
        assert not os.path.exists(waiting_path()), "没记着的会话，清除事件不碰文件"
        hook({"session_id": "w1", "hook_event_name": "PermissionRequest", "tool_name": "Bash", "cwd": "/Users/x/p",
              "tool_use_id": "T1", "transcript_path": "/Users/x/.claude/projects/p/w1.jsonl", "tool_input": {"command": "rm -rf secret-dir"}})
        w = waiting()["w1"]
        assert w["calls"]["|T1"]["state"] == "pending" and w["calls"]["|T1"]["tool"] == "Bash" and w["cwd"] == "/Users/x/p"
        assert w["transcript_path"].endswith("w1.jsonl")
        assert "secret-dir" not in open(waiting_path(), encoding="utf-8").read(), "不记命令内容"
        since = w["calls"]["|T1"]["since"]
        # 子代理 A 也在等批准；B 的工具结果只清 B 自己的，不能把 A 清掉
        hook({"session_id": "w1", "hook_event_name": "PermissionRequest", "tool_name": "Edit", "agent_id": "A", "tool_use_id": "T2"})
        hook({"session_id": "w1", "hook_event_name": "PostToolUse", "agent_id": "B", "tool_use_id": "T3"})
        assert set(waiting()["w1"]["calls"]) == {"|T1", "A|T2"}, waiting()
        hook({"session_id": "w1", "hook_event_name": "Notification", "notification_type": "permission_prompt", "message": "私密正文"})
        c = waiting()["w1"]["calls"]
        assert c["|T1"]["state"] == "permission" and c["|T1"]["since"] == since, "确认后等待起点不变"
        assert "私密正文" not in open(waiting_path(), encoding="utf-8").read()
        hook({"session_id": "w1", "hook_event_name": "SubagentStop", "agent_id": "A"})
        assert set(waiting()["w1"]["calls"]) == {"|T1"}
        hook({"session_id": "w1", "hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_use_id": "T1"})
        assert not waiting()["w1"]["calls"]
        hook({"session_id": "w1", "hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_use_id": "T1"})
        assert not waiting()["w1"]["calls"], "已有结果的调用，迟到的 PermissionRequest 不能复活"
        # 按官方形态：PermissionRequest 不带 tool_use_id，PostToolUse 带 → 也要清掉
        hook({"session_id": "w4", "hook_event_name": "PermissionRequest", "tool_name": "Bash"})
        hook({"session_id": "w4", "hook_event_name": "Notification", "notification_type": "permission_prompt"})
        assert waiting()["w4"]["calls"]["|"]["state"] == "permission"
        hook({"session_id": "w4", "hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_use_id": "toolu_X"})
        assert not waiting()["w4"]["calls"], waiting()["w4"]
        # 没有 PermissionRequest 的独立批准通知（沙箱联网）也要显示，之后有结果即清
        hook({"session_id": "w5", "hook_event_name": "Notification", "notification_type": "permission_prompt"})
        assert waiting()["w5"]["calls"]["|notify"]["state"] == "permission"
        hook({"session_id": "w5", "hook_event_name": "PostToolUse", "tool_use_id": "toolu_Y"})
        assert not waiting()["w5"]["calls"]
        hook({"session_id": "w3", "hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_use_id": "T9"})
        hook({"session_id": "w3", "hook_event_name": "PermissionDenied", "tool_use_id": "T9"})
        assert not waiting()["w3"]["calls"], "拒绝也算这次调用结束"
        hook({"session_id": "w2", "hook_event_name": "Notification", "notification_type": "idle_prompt"})
        hook({"session_id": "w2", "hook_event_name": "Notification", "notification_type": "auth_success"})
        assert _num(waiting()["w2"]["input"]) and not waiting()["w2"]["calls"]
        hook({"session_id": "w2", "hook_event_name": "UserPromptSubmit", "prompt": "私密"})
        assert "w2" not in waiting()
        # 锁：并发的 PermissionRequest / 清除事件不丢更新
        procs = [subprocess.Popen([sys.executable, script_path(), HOOK_FLAG, "claude"], stdin=subprocess.PIPE, env=dict(os.environ, HOME=tmp))
                 for _ in range(12)]
        for i, pr in enumerate(procs):
            pr.communicate(json.dumps({"session_id": "c", "hook_event_name": "PermissionRequest", "tool_use_id": "P%d" % i}).encode())
        assert len(waiting()["c"]["calls"]) == 12
        hook({"session_id": "c", "hook_event_name": "Stop"})
        hook("not a dict")                                   # 坏输入也零输出、不报错
        assert os.stat(waiting_path()).st_mode & 0o777 == 0o600
        assert uninstall_hooks("claude") == "uninstalled" and uninstall_hooks("claude") == "not-installed"
        h = load_settings(cpath)["hooks"]
        assert h == {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo user-hook"}]}],
                     "Stop": [{"hooks": [{"type": "command", "command": "echo user-stop"}]}],
                     "Notification": [{"hooks": [{"type": "command", "command": "echo vibegauge-statusline.py --hook"}]}],
                     "PostToolBatch": []}, h
        s0 = load_settings(cpath); s0.pop("hooks"); write_json(cpath, s0, indent=2)
        # 还原：恢复成原来的 statusLine，键顺序不变
        assert uninstall("claude") == "uninstalled"
        s = load_settings(cpath)
        assert s["statusLine"] == orig and list(s.keys()) == ["theme", "statusLine", "zeta"]
        assert not os.path.exists(state_path("claude"))

        # 2. 原来没配状态栏（也没有配置文件）：显示一行简短额度；还原时把 statusLine 整个拿掉
        apath = settings_path("agy")
        assert install("agy") == "installed" and os.path.exists(apath)
        out = run_as_statusline("agy", {"model": {"id": "claude-opus-4-6-thinking"},
                                        "quota": {"5h": {"remaining_fraction": 0.7, "reset_in_seconds": 3600},
                                                  "gemini-weekly": {"remaining_fraction": 0.4, "reset_in_seconds": 86400}}})
        pools = read_json(out_path("agy"), {})["pools"]
        assert abs(pools["3p"]["5h"]["remaining_fraction"] - 0.7) < 1e-9, "没前缀的键归当前模型所在的池"
        assert pools["gemini"]["weekly"]["reset_at"] > time.time() + 80000
        assert "3p 5h 30%" in out and "7d 60%" in out, out
        # 再来一轮只有 gemini-5h：旧的 3p 条目要保留
        run_as_statusline("agy", {"model": {"id": "gemini-3.8-flash"}, "quota": {"gemini-5h": {"remaining_fraction": 0.9}}})
        pools = read_json(out_path("agy"), {})["pools"]
        assert "5h" in pools["3p"] and abs(pools["gemini"]["5h"]["remaining_fraction"] - 0.9) < 1e-9
        assert uninstall("agy") == "uninstalled" and "statusLine" not in load_settings(apath)

        # 3. 用户配置不是合法 JSON：拒绝接管，原文件一个字节不动
        with open(cpath, "w") as f:
            f.write("{ // 手写注释\n}")
        try:
            install("claude")
            raise AssertionError("非法 JSON 不该接管")
        except ValueError:
            pass
        assert open(cpath).read() == "{ // 手写注释\n}"

        # 4. settings.json 是软链接（dotfiles 仓库管理）：接管/还原后仍是软链接，改的是真实文件
        real = os.path.join(tmp, "dotfiles-settings.json")
        write_json(real, {"statusLine": orig}, mode=0o644, indent=2)
        os.remove(cpath)
        os.symlink(real, cpath)
        assert install("claude") == "installed" and os.path.islink(cpath)
        assert MARK in load_settings(real)["statusLine"]["command"]
        # 非 UTF-8 区域设置 + 中文路径：照样截到额度、原状态栏照样收到原字节
        env = dict(os.environ, HOME=tmp, LANG="C", LC_ALL="C", PYTHONUTF8="0", PYTHONIOENCODING="")
        cn = {"model": "我的模型", "cwd": "/Users/x/项目", "rate_limits": {"five_hour": {"used_percentage": 33}}}
        r = subprocess.run([sys.executable, script_path(), "claude"], input=json.dumps(cn, ensure_ascii=False).encode("utf-8"),
                           capture_output=True, env=env, timeout=20)
        assert r.returncode == 0 and r.stdout.decode("utf-8").strip() == "ORIG 我的模型", r
        assert read_json(out_path("claude"), {})["five_hour"]["used_percentage"] == 33
        assert uninstall("claude") == "uninstalled" and os.path.islink(cpath) and load_settings(real)["statusLine"] == orig

        # 5. 同时连接 Claude 和 agy：各自的原命令记录互不覆盖，分别还原
        write_json(cpath, {"statusLine": orig}, mode=0o644, indent=2)
        write_json(apath, {"statusLine": {"type": "command", "command": "agy-hud"}}, mode=0o644, indent=2)
        assert install("claude") == "installed" and install("agy") == "installed"
        assert uninstall("claude") == "uninstalled" and load_settings(real)["statusLine"] == orig
        assert uninstall("agy") == "uninstalled" and load_settings(apath)["statusLine"]["command"] == "agy-hud"
        # 状态记录丢了：用接管时的备份还原，而不是当成「原来没有」删掉
        assert install("agy") == "installed"
        os.remove(state_path("agy"))
        assert uninstall("agy") == "uninstalled" and load_settings(apath)["statusLine"]["command"] == "agy-hud"

        # 6. 写回前文件被别人改了：基于新内容重来，别人的修改不丢
        calls = []

        def change(settings, raw):
            if not calls:                      # 第一次读完之后，模拟 CLI 改了 theme
                with open(apath, "w") as f:
                    json.dump(dict(settings, theme="user-new"), f)
            calls.append(1)
            return dict(settings, mine=1), "ok"
        assert edit_settings(apath, change) == "ok" and len(calls) == 2
        s = load_settings(apath)
        assert s["theme"] == "user-new" and s["mine"] == 1

        # 7. 原命令挂住：超时后整个进程组被清掉，不留后台子进程
        t0 = time.time()
        assert run_original("sleep 37.25 & sleep 37.5; echo never", b"", timeout=1) == b""
        assert time.time() - t0 < 5
        time.sleep(0.3)
        assert subprocess.run(["pgrep", "-f", "sleep 37.25"], capture_output=True).returncode == 1, "后台子进程没被清掉"

        # 8. 防套娃：原命令直接写着自己不转；经包装脚本绕回来（环境变量在）也不转；状态文件别人可写 → 不信任
        env = dict(os.environ, HOME=tmp)
        write_json(state_path("claude"), {"original": "/usr/bin/python3 %s claude" % script_path()})
        r = subprocess.run([sys.executable, script_path(), "claude"], input="not json", capture_output=True,
                           text=True, env=env, timeout=20)
        assert r.returncode == 0
        write_json(state_path("claude"), {"original": "echo CHAINED"})
        r = subprocess.run([sys.executable, script_path(), "claude"], input="{}", capture_output=True,
                           text=True, env=dict(env, **{REENTRY: "1"}), timeout=20)
        assert "CHAINED" not in r.stdout
        assert subprocess.run([sys.executable, script_path(), "claude"], input="{}", capture_output=True,
                              text=True, env=env, timeout=20).stdout.strip() == "CHAINED"
        os.chmod(state_path("claude"), 0o666)
        assert "CHAINED" not in subprocess.run([sys.executable, script_path(), "claude"], input="{}", capture_output=True,
                                               text=True, env=env, timeout=20).stdout, "别人可写的状态文件不该被执行"
        print("statusline selftest OK")
    finally:
        if real_home is not None:
            os.environ["HOME"] = real_home
        shutil.rmtree(tmp, ignore_errors=True)


def main() -> None:
    args = sys.argv[1:]
    if args == ["--selftest"]:
        return selftest()
    if len(args) == 2 and args[0] in ("--install", "--uninstall") and args[1] in ("claude", "agy"):
        try:
            print((install if args[0] == "--install" else uninstall)(args[1]))
        except (OSError, ValueError) as e:
            print("error: %s: %s" % (settings_path(args[1]), e), file=sys.stderr)
            sys.exit(1)
        return
    if len(args) == 2 and args[0] in ("--install-hooks", "--uninstall-hooks") and args[1] == "claude":
        try:
            print((install_hooks if args[0] == "--install-hooks" else uninstall_hooks)(args[1]))
        except (OSError, ValueError) as e:
            print("error: %s: %s" % (settings_path(args[1]), e), file=sys.stderr)
            sys.exit(1)
        return
    if len(args) == 2 and args[0] == HOOK_FLAG and args[1] == "claude":
        return run_hook()
    if len(args) == 1 and args[0] in ("claude", "agy"):
        return run(args[0])
    print(__doc__, file=sys.stderr)
    sys.exit(2)


if __name__ == "__main__":
    main()
