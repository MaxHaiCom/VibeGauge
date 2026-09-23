#!/usr/bin/env python3
"""
VibeGauge API 记账代理 —— 纯 stdlib，Python ≥ 3.9（/usr/bin/python3 即可），零依赖。

用法（上游写在路径里，零配置）：
  ANTHROPIC_BASE_URL=http://127.0.0.1:18790/https://open.bigmodel.cn/api/anthropic
  OPENAI_BASE_URL=http://127.0.0.1:18790/https://api.deepseek.com/v1
  → 请求 /https://HOST/任意路径 原样转发到 HOST，响应流式透传，同时从响应里抠 model + usage 记账。

产物（目录 ~/.config/vibegauge/）：
  api-calls.jsonl   每次调用一行：ts/host/provider/model/ctx/cache_read/cache_write/out/think/status/ms
  api-quota.json    各上游的额度/余额（代理从请求头看到 key，只放内存，定时查厂商用量接口）
  GET /_vibegauge/health   运行状态

自测：python3 vibegauge-proxy.py --selftest（本地起假上游，验证流式/非流式解析）
"""
import gzip
import hashlib
import http.client
import json
import os
import re
import sys
import threading
import time
import traceback
import urllib.parse
import urllib.request
import zlib
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, Optional

PORT = int(os.environ.get("VIBEGAUGE_PROXY_PORT", "18790"))
DIR = os.path.expanduser(os.environ.get("VIBEGAUGE_DIR", "~/.config/vibegauge"))
CALLS = os.path.join(DIR, "api-calls.jsonl")
QUOTA = os.path.join(DIR, "api-quota.json")
QUOTA_INTERVAL = int(os.environ.get("VIBEGAUGE_QUOTA_INTERVAL", "300"))
PROXY_CONF = os.path.join(DIR, "proxy.json")
START = time.time()

# host 子串 → 展示名
PROVIDERS = [
    ("api.anthropic.com", "Anthropic"), ("api.openai.com", "OpenAI"), ("api.x.ai", "xAI"),
    ("generativelanguage.googleapis.com", "Gemini"), ("openrouter.ai", "OpenRouter"),
    ("open.bigmodel.cn", "GLM"), ("api.z.ai", "GLM"), ("volces.com", "火山豆包"),
    ("xiaomimimo.com", "MiMo"), ("moonshot.cn", "Kimi"), ("moonshot.ai", "Kimi"),
    ("minimaxi.com", "MiniMax"), ("minimax.io", "MiniMax"), ("deepseek.com", "DeepSeek"),
    ("dashscope.aliyuncs.com", "通义"), ("hunyuan", "混元"), ("siliconflow", "硅基流动"),
    ("localhost", "本地"), ("127.0.0.1", "本地"),
]

# 客户端 → 上游 不该透传的头；Accept-Encoding 去掉是为了拿到明文好解析
DROP_REQ = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer",
            "transfer-encoding", "upgrade", "host", "content-length", "accept-encoding"}
DROP_RESP = {"transfer-encoding", "content-length", "connection", "keep-alive"}

_lock = threading.Lock()
_keys: Dict[str, Dict[str, str]] = {}      # "host#指纹" → {header: value}，只在内存
_stats = {"calls": 0, "parsed": 0, "errors": 0}
_hosts_seen: Dict[str, float] = {}


# 额度类响应头（Anthropic 用 anthropic-ratelimit-*，OpenAI 用 x-ratelimit-*）。
# 被动抓：厂商愿意在真实调用里给的额度，我们顺手记下来，绝不为了查额度去多发请求。
def quota_headers(resp) -> Dict[str, str]:
    out = {}
    for k, v in resp.getheaders():
        kl = k.lower()
        if "ratelimit" in kl or "rate-limit" in kl or "quota" in kl:
            out[kl] = v[:80]
    return out


def provider_of(host: str, path: str = "") -> str:
    # 火山方舟 Coding Plan 与按量付费是两个 Base URL：/api/coding/* 才吃套餐额度，
    # /api/v3/* 是后付费。分成两张卡，免得把两种账混在一起。
    if "volces.com" in host.lower():
        return "火山方舟 Coding" if path.startswith("/api/coding") else "火山豆包(按量)"
    h = host.lower()
    for sub, name in PROVIDERS:
        if sub in h:
            return name
    return h.split(":")[0]


# ---------------------------------------------------------------- 上游代理
# 顺序：proxy.json 的 upstream（"direct" = 强制直连）> VIBEGAUGE_UPSTREAM_PROXY > 环境变量 / macOS 系统代理。
# 后两者由 urllib.request.getproxies() 给出：LaunchAgent 不继承 shell 的 HTTPS_PROXY，但系统代理（ClashX 等
# 「设置为系统代理」）照样读得到。只支持 http:// 代理（CONNECT 隧道）；本机回环地址永远直连。
_proxy_cache: Dict[str, Any] = {"at": 0.0, "mtime": None, "conf": {}}


def _proxy_conf() -> Dict[str, Any]:
    now = time.time()
    try:
        mtime = os.stat(PROXY_CONF).st_mtime
    except OSError:
        mtime = None
    c = _proxy_cache
    if now - c["at"] < 30 and mtime == c["mtime"]:
        return c["conf"]
    conf: Dict[str, Any] = {}
    if mtime is not None:
        try:
            j = json.load(open(PROXY_CONF, encoding="utf-8"))
            conf = j if isinstance(j, dict) else {}
        except (OSError, ValueError):
            conf = {}
    c.update(at=now, mtime=mtime, conf=conf)
    return conf


def _is_loopback(host: str) -> bool:
    h = host.lower().strip("[]")
    return h == "localhost" or h == "::1" or h.startswith("127.")


def pick_proxy(scheme: str, host: str) -> Optional[str]:
    """返回要走的 http:// 代理 URL，或 None = 直连。host 不含端口。"""
    if _is_loopback(host):
        return None
    conf = _proxy_conf()
    explicit = conf.get("upstream") if isinstance(conf.get("upstream"), str) else os.environ.get("VIBEGAUGE_UPSTREAM_PROXY")
    if explicit is not None:
        explicit = explicit.strip()
        if explicit in ("", "direct"):
            return None
        if any(host == d or host.endswith("." + d.lstrip("*.")) for d in conf.get("no_proxy") or [] if isinstance(d, str)):
            return None
        return explicit if explicit.startswith("http://") else None
    try:
        if urllib.request.proxy_bypass(host):           # 系统代理的例外列表 / NO_PROXY
            return None
        url = urllib.request.getproxies().get(scheme)
    except Exception:
        return None
    return url if url and url.startswith("http://") else None


def redact_proxy(url: Optional[str]) -> str:
    if not url:
        return "direct"
    p = urllib.parse.urlsplit(url)
    return "http://%s:%s" % (p.hostname, p.port or 80) + (" (auth)" if p.username else "")


def open_upstream(scheme: str, hostport: str, timeout: float, proxy: Optional[str] = None):
    """建到上游的连接；proxy 非空时经 HTTP 代理 CONNECT 隧道（https 与 http 上游都走隧道）"""
    cls = http.client.HTTPSConnection if scheme == "https" else http.client.HTTPConnection
    if not proxy:
        return cls(hostport, timeout=timeout)
    p = urllib.parse.urlsplit(proxy)
    headers = {}
    if p.username:
        import base64
        cred = "%s:%s" % (urllib.parse.unquote(p.username), urllib.parse.unquote(p.password or ""))
        headers["Proxy-Authorization"] = "Basic " + base64.b64encode(cred.encode()).decode()
    conn = cls(p.hostname, p.port or 80, timeout=timeout)
    conn.set_tunnel(hostport, headers=headers)
    return conn


def upstream(scheme: str, hostport: str, timeout: float):
    host = urllib.parse.urlsplit("//" + hostport).hostname or hostport
    return open_upstream(scheme, hostport, timeout, pick_proxy(scheme, host))


def ensure_dir() -> None:
    os.makedirs(DIR, mode=0o700, exist_ok=True)
    os.chmod(DIR, 0o700)


def private_opener(path, flags):
    fd = os.open(path, flags, 0o600)
    try:
        os.fchmod(fd, 0o600)  # 旧文件也可能由宽松 umask 创建，写入前一起收紧
        return fd
    except Exception:
        os.close(fd)
        raise


def append_call(rec: Dict[str, Any]) -> None:
    ensure_dir()
    line = json.dumps(rec, ensure_ascii=False)
    with _lock:
        with open(CALLS, "a", encoding="utf-8", opener=private_opener) as f:
            f.write(line + "\n")


def key_fingerprint(v: str) -> str:
    return hashlib.sha256(v.encode()).hexdigest()[:8]


def redact_path(path: str) -> str:
    """记账只留路径，抹掉 query string —— Gemini 等把 API key 放在 ?key=... 里，写进文件就是泄露"""
    head = path.split("?", 1)[0]
    return head[:120] + ("?…" if "?" in path else "")


def redact_text(s: str) -> str:
    # 异常会夹带 URL、认证头或上游回显；必须先脱敏再截断，免得只截掉凭据的识别部分。
    s = re.sub(r"\?[^\s\"']*", "?…", s)
    s = re.sub(r"(\bBearer\s+|\b(?:key|token)\s*=\s*[\"']?)([^\s\"'&,;]+)",
               lambda m: m[1] + m[2][:4] + "…", s, flags=re.IGNORECASE)
    s = re.sub(r"(?<![A-Za-z0-9_-])(?:sk-(?:ant-|or-)?|ark-|AIza)[A-Za-z0-9_./+=-]+…?",
               lambda m: m[0][:4] + "…", s)
    return re.sub(r"(?<![A-Za-z0-9_+/-])[A-Za-z0-9_+/-]{32,}={0,2}",
                  lambda m: m[0][:4] + "…", s)


def log_exception(exc_type, exc, tb) -> None:
    print(redact_text("".join(traceback.format_exception(exc_type, exc, tb))), file=sys.stderr, end="", flush=True)


def host_matches(host: str, domain: str) -> bool:
    h = host.lower().split(":", 1)[0]
    return h == domain or h.endswith("." + domain)


def capture_key(host: str, headers) -> Optional[str]:
    found = {}
    for name in ("x-api-key", "authorization", "x-goog-api-key"):
        v = headers.get(name)
        if v:
            found[name] = v
    if not found:
        return None
    v = next(iter(found.values()))
    fp = key_fingerprint(v)
    # 按「上游 + 账户」分开存：同一上游换着用两个 key 时，余额 / 套餐探针各查各的，不互相覆盖
    with _lock:
        _keys["%s#%s" % (host, fp)] = found
        _hosts_seen[host] = time.time()
    return fp


# ---------------------------------------------------------------- usage 解析

def _set(u: Dict[str, Any], k: str, v: Any) -> None:
    # 上游偶尔回负数或 NaN：不记，免得把累计账冲成负的
    if isinstance(v, (int, float)) and not isinstance(v, bool) and v == v and v >= 0:
        u[k] = int(v)
        u["parsed"] = True


def apply_anthropic_usage(u: Dict[str, Any], us: Dict[str, Any]) -> None:
    _set(u, "_in", us.get("input_tokens"))
    _set(u, "cache_read", us.get("cache_read_input_tokens"))
    _set(u, "cache_write", us.get("cache_creation_input_tokens"))
    _set(u, "out", us.get("output_tokens"))
    u["ctx"] = u.get("_in", 0) + u.get("cache_read", 0) + u.get("cache_write", 0)


def apply_json(u: Dict[str, Any], j: Any) -> None:
    if not isinstance(j, dict):
        return
    t = j.get("type")
    # Anthropic：非流式整包 / 流式 message_start + message_delta
    msg = j.get("message") if t == "message_start" else (j if t == "message" else None)
    if isinstance(msg, dict):
        if isinstance(msg.get("usage"), dict):
            apply_anthropic_usage(u, msg["usage"])
            if t == "message" and isinstance(msg["usage"].get("output_tokens"), (int, float)):
                u["_final_usage"] = True
        if msg.get("model"):
            u["model"] = msg["model"]
    if t == "message_delta" and isinstance(j.get("usage"), dict):
        apply_anthropic_usage(u, j["usage"])
        if isinstance(j["usage"].get("output_tokens"), (int, float)):
            u["_final_usage"] = True
    # OpenAI 兼容：usage.prompt_tokens / completion_tokens（流式在最后一个 chunk）
    us = j.get("usage")
    if isinstance(us, dict) and ("prompt_tokens" in us or "completion_tokens" in us):
        _set(u, "ctx", us.get("prompt_tokens"))
        _set(u, "out", us.get("completion_tokens"))
        _set(u, "cache_read", _details(us, "prompt_tokens_details").get("cached_tokens"))
        _set(u, "think", _details(us, "completion_tokens_details").get("reasoning_tokens"))
        # completion_tokens 已含 reasoning_tokens；think 只是其中的明细。
        u["_final_usage"] = True
        if j.get("model"):
            u["model"] = j["model"]
    # Responses：整包对象 / response.completed 中的 response.usage。
    response = j.get("response") if t in ("response.completed", "response.incomplete", "response.failed") else j
    if isinstance(response, dict) and t not in ("message", "message_start", "message_delta"):
        ru = response.get("usage")
        if isinstance(ru, dict) and ("input_tokens" in ru or "output_tokens" in ru):
            _set(u, "ctx", ru.get("input_tokens"))
            _set(u, "out", ru.get("output_tokens"))
            _set(u, "cache_read", _details(ru, "input_tokens_details").get("cached_tokens"))
            _set(u, "think", _details(ru, "output_tokens_details").get("reasoning_tokens"))
            u["_final_usage"] = True
            if response.get("model"):
                u["model"] = response["model"]
    # Gemini
    um = j.get("usageMetadata")
    if isinstance(um, dict):
        _set(u, "ctx", um.get("promptTokenCount"))
        _set(u, "_candidates", um.get("candidatesTokenCount"))
        _set(u, "cache_read", um.get("cachedContentTokenCount"))
        _set(u, "think", um.get("thoughtsTokenCount"))
        # Gemini 的 candidates 不含 thoughts。保存累计快照，重复事件不重复相加。
        u["out"] = u.get("_candidates", 0) + u.get("think", 0)
        u["_final_usage"] = True
        if j.get("modelVersion"):
            u["model"] = j["modelVersion"]
    # Ollama 原生
    if "eval_count" in j or "prompt_eval_count" in j:
        _set(u, "ctx", j.get("prompt_eval_count"))
        _set(u, "out", j.get("eval_count"))
        u["_final_usage"] = True
        if j.get("model"):
            u["model"] = j["model"]


def _details(usage: Dict[str, Any], key: str) -> Dict[str, Any]:
    value = usage.get(key)
    return value if isinstance(value, dict) else {}


class UsageParser:
    """只保留当前 SSE 行/事件与累计 usage，不随整条流增长。

    单事件和非流式 JSON 都有硬上限；超限仍透传，但明确记为不完整。
    gzip 也分块解压，避免压缩后的短响应导致无界解压内存。
    """
    EVENT_LIMIT = 1024 * 1024
    JSON_LIMIT = 8 * 1024 * 1024
    CHUNK = 65536

    def __init__(self, req_model: Optional[str], content_type: str, encoding: str):
        self.u: Dict[str, Any] = {"model": req_model, "ctx": 0, "cache_read": 0,
                                  "cache_write": 0, "out": 0, "think": 0, "parsed": False}
        self.mode = "sse" if "text/event-stream" in content_type.lower() else None
        self.buf = bytearray()
        self.event = bytearray()
        self.discard_line = False
        self.discard_event = False
        self.after_cr = False
        self.error: Optional[str] = None
        enc = encoding.strip().lower()
        self.decoder = zlib.decompressobj(16 + zlib.MAX_WBITS) if enc == "gzip" else None
        self.decode_failed = enc not in ("", "identity", "gzip")
        if self.decode_failed:
            self.error = "unsupported_content_encoding"

    def fail(self, error: str) -> None:
        if self.error is None:
            self.error = error

    def _json(self, payload: bytes) -> None:
        try:
            j = json.loads(payload)
            apply_json(self.u, j)
            if isinstance(j, dict) and (j.get("type") in ("error", "response.failed", "response.incomplete")
                                       or j.get("error") or j.get("status") in ("failed", "incomplete")):
                self.fail("upstream_response_error")
        except (ValueError, UnicodeError, RecursionError, TypeError, OverflowError):
            # 不保存异常正文：JSON 异常和厂商 error 可能带响应正文或凭据。
            self.fail("invalid_usage_json")

    def _line(self) -> None:
        if not self.buf and not self.discard_line:
            if self.event and not self.discard_event:
                payload = bytes(self.event).strip()
                if payload and payload != b"[DONE]":
                    self._json(payload)
            self.event.clear()
            self.discard_event = False
        elif not self.discard_event and self.buf.startswith(b"data:"):
            data = self.buf[5:]
            if data.startswith(b" "):
                del data[:1]
            if len(self.event) + len(data) + 1 > self.EVENT_LIMIT:
                self.fail("sse_event_too_large")
                self.event.clear()
                self.discard_event = True
            else:
                self.event.extend(data)
                self.event.append(10)  # SSE 多条 data 行按换行拼接后才解析
        self.buf.clear()
        self.discard_line = False

    def _plain(self, data: bytes) -> None:
        if self.mode is None:
            # 兼容漏报 Content-Type 的上游；最多暂存少量前缀，不等待整个响应。
            data = bytes(self.buf) + data
            self.buf.clear()
            data = data.lstrip(b" \t\r\n")
            if not data:
                return
            if any(prefix.startswith(data) for prefix in (b"data:", b"event:", b"\xef\xbb\xbf")):
                self.buf.extend(data)
                return
            if data.startswith(b"\xef\xbb\xbf"):
                data = data[3:]
            self.mode = "sse" if data.startswith((b"data:", b"event:", b":")) else "json"
        if self.mode == "json":
            if len(self.buf) + len(data) > self.JSON_LIMIT:
                self.fail("json_body_too_large")
                self.buf.clear()
                self.mode = "discard"
            else:
                self.buf.extend(data)
            return
        if self.mode != "sse":
            return
        # 同时接受 LF、CRLF 和 CR，网络块可切在任何 UTF-8 字符/换行中间。
        start = 0
        for match in re.finditer(b"[\r\n]", data):
            end = match.start()
            part = data[start:end]
            if part:
                self.after_cr = False
            self._part(part)
            if not (data[end] == 10 and self.after_cr):
                self._line()
            self.after_cr = data[end] == 13
            start = end + 1
        if start < len(data):
            self.after_cr = False
            self._part(data[start:])

    def _part(self, part: bytes) -> None:
        if self.discard_line:
            return
        if len(self.buf) + len(part) > self.EVENT_LIMIT:
            self.fail("sse_event_too_large")
            self.buf.clear()
            self.event.clear()
            self.discard_line = self.discard_event = True
        else:
            self.buf.extend(part)

    def feed(self, data: bytes) -> None:
        if self.decode_failed:
            return
        if self.decoder is None:
            self._plain(data)
            return
        try:
            while data:
                # gzip 允许拼接多个 member；每次解压的输出也限制为 CHUNK。
                if self.decoder.eof:
                    self.decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
                self._plain(self.decoder.decompress(data, self.CHUNK))
                data = self.decoder.unused_data if self.decoder.eof else self.decoder.unconsumed_tail
        except zlib.error:
            self.fail("invalid_gzip")
            self.decode_failed = True

    def finish(self, complete: bool = True) -> Dict[str, Any]:
        if not complete:
            self.fail("incomplete_response")
        if self.decoder is not None and not self.decoder.eof:
            self.fail("incomplete_gzip")
        if self.mode == "json" and complete and not self.decode_failed:
            self._json(bytes(self.buf))
        elif self.mode == "sse" and (self.buf or self.event or self.discard_line or self.discard_event):
            self.fail("incomplete_sse_event")
        if not self.u["parsed"]:
            self.fail("usage_not_found")
        elif self.mode == "sse" and not self.u.get("_final_usage"):
            self.fail("final_usage_not_found")
        u = {k: v for k, v in self.u.items() if not k.startswith("_")}
        # 已收到的计数保留作诊断，但不把部分 usage 标成解析成功。
        u["parsed"] = bool(u["parsed"] and not self.error)
        if self.error:
            u["error"] = self.error
        self.buf.clear()
        self.event.clear()
        return u


def parse_usage(req_model: Optional[str], content_type: str, body: bytes, encoding: str) -> Dict[str, Any]:
    parser = UsageParser(req_model, content_type, encoding)
    for start in range(0, len(body), parser.CHUNK):
        parser.feed(body[start:start + parser.CHUNK])
    return parser.finish()


# ---------------------------------------------------------------- 代理

class ProxyServer(ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        # stdlib 默认会把未捕获异常直接打进 stderr（LaunchAgent 的 proxy.log）。
        log_exception(*sys.exc_info())


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "VibeGaugeProxy/1"

    def log_message(self, fmt, *args):  # 安静
        pass

    def parse_request(self):
        if not super().parse_request():
            return False
        port = self.server.server_address[1]
        hosts = self.headers.get_all("Host", [])
        # 只拦浏览器专属的头：Origin、Sec-Fetch-Site、Sec-Fetch-Dest。
        # 不能拦整个 Sec-Fetch-*：Node 自带的 fetch（undici）默认会发 sec-fetch-mode，
        # 拦了就会把 Gemini CLI 这类 Node 工具经代理的请求全部 403（2026-09-19 实测）。
        browser = {"origin", "sec-fetch-site", "sec-fetch-dest"}
        if (any(k.lower() in browser for k in self.headers)
                or len(hosts) != 1 or hosts[0] not in ("127.0.0.1:%d" % port, "localhost:%d" % port)):
            # 拒绝后关连接，未读取的请求体不能被当成下一条请求。
            self.close_connection = True
            self._json(403, {"error": "vibegauge-proxy requires a local CLI request"})
            return False
        return True

    def do_GET(self): self._proxy()
    def do_POST(self): self._proxy()
    def do_PUT(self): self._proxy()
    def do_DELETE(self): self._proxy()
    def do_PATCH(self): self._proxy()
    def do_OPTIONS(self): self._proxy()

    def _json(self, status: int, obj: Dict[str, Any]) -> None:
        data = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _read_body(self) -> bytes:
        if (self.headers.get("Transfer-Encoding") or "").lower() == "chunked":
            out = bytearray()
            while True:
                size_line = self.rfile.readline().strip()
                size = int(size_line.split(b";")[0] or b"0", 16)
                if size == 0:
                    self.rfile.readline()
                    break
                out += self.rfile.read(size)
                self.rfile.readline()
            return bytes(out)
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def _proxy(self) -> None:
        if self.path.startswith("/_vibegauge/health"):
            with _lock:
                return self._json(200, {"ok": True, "port": PORT, "uptime_s": int(time.time() - START),
                                        "calls": _stats["calls"], "parsed": _stats["parsed"], "errors": _stats["errors"],
                                        "hosts": sorted(_hosts_seen.keys()), "dir": DIR,
                                        "upstream": redact_proxy(pick_proxy("https", "api.example.com"))})
        m = re.match(r"^/(https?)://([^/]+)(/.*)?$", self.path)
        if not m:
            return self._json(400, {"error": "path must be /https://HOST/...  e.g. ANTHROPIC_BASE_URL=http://127.0.0.1:%d/https://api.anthropic.com" % PORT})
        scheme, hostport, rest = m.group(1), m.group(2), m.group(3) or "/"
        body = self._read_body()
        req_model = None
        stream = False
        if body:
            try:
                rj = json.loads(body)
                if isinstance(rj, dict):
                    req_model = rj.get("model")
                    stream = bool(rj.get("stream"))
            except ValueError:
                pass
        if req_model is None:
            mm = re.search(r"/models/([^:/?]+)", rest)   # Gemini 模型在路径里
            if mm:
                req_model = mm.group(1)
                stream = "stream" in rest.lower()
        hdrs = {k: v for k, v in self.headers.items() if k.lower() not in DROP_REQ}
        hdrs["Host"] = hostport
        hdrs["Accept-Encoding"] = "identity"
        if body:
            hdrs["Content-Length"] = str(len(body))
        key_fp = capture_key(hostport, self.headers)
        record = self.command == "POST"          # GET /models、/auth/key 之类只转发不记账

        t0 = time.time()
        conn = None
        rec: Dict[str, Any] = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + "Z", "epoch": round(t0, 3),
                               "host": hostport, "provider": provider_of(hostport, rest), "path": redact_path(rest),
                               "model": req_model, "stream": stream, "key": key_fp}
        parser = UsageParser(req_model, "", "")
        received = 0
        complete = False
        response_started = False
        phase = "upstream"
        rec["status"] = 502
        sent = False            # 请求已完整发给上游：此后才算「到了厂商」（套餐按请求数估额度要用）
        try:
            conn = upstream(scheme, hostport, 600)
            conn.request(self.command, rest, body=body, headers=hdrs)
            sent = True
            resp = conn.getresponse()
            rec["status"] = resp.status
            rl = quota_headers(resp)
            if rl:
                rec["rl"] = rl
            clen = resp.getheader("Content-Length")
            chunked = clen is None
            parser = UsageParser(req_model, resp.getheader("Content-Type") or "",
                                 resp.getheader("Content-Encoding") or "")
            phase = "client"
            response_started = True
            self.send_response(resp.status, resp.reason)
            for k, v in resp.getheaders():
                if k.lower() not in DROP_RESP:
                    self.send_header(k, v)
            if chunked:
                self.send_header("Transfer-Encoding", "chunked")
            else:
                self.send_header("Content-Length", clen)
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            while True:
                phase = "upstream"
                data = resp.read1(65536)          # 有多少给多少，SSE 不等满块
                if not data:
                    # read1 与 read 不同：Content-Length 未读满也可能直接返回 EOF。
                    if resp.length not in (None, 0):
                        raise http.client.IncompleteRead(b"", resp.length)
                    break
                received += len(data)
                parser.feed(data)
                phase = "client"
                if chunked:
                    self.wfile.write(b"%x\r\n" % len(data) + data + b"\r\n")
                else:
                    self.wfile.write(data)
                self.wfile.flush()
            phase = "client"
            if chunked:
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            complete = True
        except Exception as e:
            # 已发响应头后只能断开，不能再写 502 或成功的 chunked 结束符。
            self.close_connection = True
            rec["error"] = ("%s_error: %s" % (phase, type(e).__name__) if response_started
                            else redact_text(str(e))[:200])
            if not response_started:
                try:
                    self._json(502, {"error": "vibegauge-proxy upstream error: %s" % type(e).__name__})
                except OSError:
                    pass
        finally:
            try:
                if conn is not None:
                    conn.close()
            finally:
                u = parser.finish(complete)
                parse_error = u.pop("error", None)
                rec.update(u)
                rec["model"] = u.get("model") or req_model
                rec.update({"ms": int((time.time() - t0) * 1000), "bytes": received, "complete": complete, "sent": sent})
                if parse_error and "error" not in rec:
                    rec["error"] = parse_error
                if record:
                    with _lock:
                        _stats["calls"] += 1
                        if rec["parsed"]:
                            _stats["parsed"] += 1
                        # 没找到 usage 之类的解析问题不算请求失败（embeddings 等本来就没有 usage）
                        if rec["status"] >= 400 or not complete:
                            _stats["errors"] += 1
                    append_call(rec)


# ---------------------------------------------------------------- 额度 / 余额探针
# 每个探针：(域名, 函数)。只匹配该域名及其子域，避免把中转站的 key 发给官方。
# 只放有公开文档 / 已实测的接口，没有的厂商不猜。

def _get_json(host: str, path: str, headers: Dict[str, str], timeout: int = 15) -> Any:
    conn = upstream("https", host, timeout)
    try:
        conn.request("GET", path, headers=dict(headers, **{"Accept": "application/json", "User-Agent": "VibeGauge/1"}))
        r = conn.getresponse()
        raw = r.read()
        if r.status >= 400:
            raise RuntimeError("HTTP %d %s" % (r.status, redact_text(raw.decode("utf-8", "replace"))[:120]))
        return json.loads(raw)
    finally:
        conn.close()


def _bearer(hdrs: Dict[str, str]) -> Dict[str, str]:
    a = hdrs.get("authorization")
    if a:
        return {"Authorization": a}
    k = hdrs.get("x-api-key") or hdrs.get("x-goog-api-key") or ""
    return {"Authorization": "Bearer " + k}


def _ms_to_s(v: Any) -> Optional[float]:
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return f / 1000.0 if f > 1e11 else f


def _iso_to_s(v: Any) -> Optional[float]:
    if not isinstance(v, str):
        return None
    try:
        # Python 3.9 的 fromisoformat 尚不识别 Z；无时区的厂商时间按 UTC。
        dt = datetime.fromisoformat(v.strip().replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.timestamp()
    except (ValueError, OverflowError):
        return None


def probe_glm(hdrs):
    """智谱 GLM Coding Plan：/api/monitor/usage/quota/limit（社区标准接口，2026-09-18 实测存在；
    无套餐时返回 code 500 "当前用户不存在coding plan"）。limits[] 按 nextResetTime 早的当 5h、晚的当周。"""
    host = "open.bigmodel.cn"
    j = _get_json(host, "/api/monitor/usage/quota/limit", _bearer(hdrs))
    if j.get("code") != 200 or not isinstance(j.get("data"), dict):
        return {"kind": "quota", "error": redact_text(str(j.get("msg") or j))[:120]}
    d = j["data"]
    limits = [l for l in (d.get("limits") or []) if isinstance(l, dict) and l.get("percentage") is not None]
    limits.sort(key=lambda l: l.get("nextResetTime") or 0)
    windows: Dict[str, Any] = {}
    if limits:
        windows["5h" if len(limits) > 1 else "weekly"] = {"used_pct": limits[0]["percentage"], "resets_at": _ms_to_s(limits[0].get("nextResetTime"))}
    if len(limits) > 1:
        windows["weekly"] = {"used_pct": limits[-1]["percentage"], "resets_at": _ms_to_s(limits[-1].get("nextResetTime"))}
    level = str(d.get("level") or "")
    return {"kind": "quota", "plan": ("Coding " + level.capitalize()) if level else "Coding Plan", "windows": windows}


def probe_minimax(hdrs):
    """MiniMax Token Plan：/v1/token_plan/remains（社区接口，未实测；按量 key 会 401/403）"""
    j = _get_json("api.minimaxi.com", "/v1/token_plan/remains", _bearer(hdrs))
    d = j.get("data") or {}
    if not d:
        return {"kind": "quota", "error": redact_text(str(j.get("message") or j))[:120]}
    now = time.time()
    windows: Dict[str, Any] = {}
    tot, used = d.get("current_interval_total_count"), d.get("current_interval_usage_count")
    if tot:
        windows["5h"] = {"used_pct": round(100.0 * float(used or 0) / float(tot)), "resets_at": now + float(d.get("remains_time") or 0) / 1000.0}
    wtot, wused = d.get("current_weekly_total_count"), d.get("current_weekly_usage_count")
    if wtot:
        windows["weekly"] = {"used_pct": round(100.0 * float(wused or 0) / float(wtot)), "resets_at": _ms_to_s(d.get("weekly_end_time"))}
    return {"kind": "quota", "plan": "Token Plan", "windows": windows}


def probe_kimi_code(hdrs):
    """Kimi Code 订阅：api.kimi.com/coding/v1/usages（社区接口，未实测）"""
    j = _get_json("api.kimi.com", "/coding/v1/usages", _bearer(hdrs))
    u = j.get("usage") or {}
    if not u:
        return {"kind": "quota", "error": redact_text(str(j))[:120]}
    limit, used = float(u.get("limit") or 0), float(u.get("used") or 0)
    windows: Dict[str, Any] = {}
    if limit > 0:
        windows["5h"] = {"used_pct": round(100.0 * used / limit), "resets_at": _iso_to_s(u.get("resetTime"))}
    return {"kind": "quota", "plan": "Kimi Code", "windows": windows}


def probe_deepseek(hdrs):
    j = _get_json("api.deepseek.com", "/user/balance", _bearer(hdrs))
    infos = j.get("balance_infos") or []
    if not infos:
        return {"kind": "balance", "available": j.get("is_available"), "balance": None}
    b = infos[0]
    return {"kind": "balance", "balance": float(b.get("total_balance", 0)), "currency": b.get("currency", "CNY"),
            "available": j.get("is_available")}


def probe_openrouter(hdrs):
    k = _get_json("openrouter.ai", "/api/v1/auth/key", _bearer(hdrs)).get("data") or {}
    out = {"kind": "balance", "usage": k.get("usage"), "limit": k.get("limit"), "limit_remaining": k.get("limit_remaining"),
           "currency": "USD"}
    try:
        c = _get_json("openrouter.ai", "/api/v1/credits", _bearer(hdrs)).get("data") or {}
        total, used = c.get("total_credits"), c.get("total_usage")
        if total is not None and used is not None:
            out["balance"] = round(float(total) - float(used), 4)
    except Exception as e:  # /credits 需要管理 key，拿不到就只报 usage
        out["credits_error"] = redact_text(str(e))[:120]
    return out


def probe_moonshot(hdrs):
    j = _get_json("api.moonshot.cn", "/v1/users/me/balance", _bearer(hdrs))
    d = j.get("data") or {}
    return {"kind": "balance", "balance": d.get("available_balance"), "cash": d.get("cash_balance"),
            "voucher": d.get("voucher_balance"), "currency": "CNY"}


PROBES = [
    ("open.bigmodel.cn", probe_glm),
    ("api.z.ai", probe_glm),
    ("minimaxi.com", probe_minimax),
    ("api.kimi.com", probe_kimi_code),
    ("deepseek.com", probe_deepseek),
    ("openrouter.ai", probe_openrouter),
    ("moonshot.cn", probe_moonshot),
    # 实测/调研无公开接口：火山方舟 coding、小米 MiMo、xAI（推理 key）—— 卡片只记调用
]


def quota_loop() -> None:
    while True:
        time.sleep(30 if time.time() - START < 60 else QUOTA_INTERVAL)
        with _lock:
            snapshot = dict(_keys)
        if not snapshot:
            continue
        result: Dict[str, Any] = {}
        try:
            if os.path.exists(QUOTA):
                result = json.load(open(QUOTA, encoding="utf-8"))
        except Exception:
            result = {}
        # 旧版只按 host 记的条目分不清是哪个账户的，写新格式时清掉
        result = {k: v for k, v in result.items() if "#" in k}
        changed = False
        for entry, hdrs in snapshot.items():
            host = entry.split("#", 1)[0]
            for sub, fn in PROBES:
                if not host_matches(host, sub):
                    continue
                row = {"provider": provider_of(host), "captured_at": time.time()}
                try:
                    row.update(fn(hdrs))
                except Exception as e:
                    row["error"] = redact_text(str(e))[:160]
                result[entry] = row
                changed = True
        if changed:
            ensure_dir()
            tmp = QUOTA + ".tmp"
            with open(tmp, "w", encoding="utf-8", opener=private_opener) as f:
                json.dump(result, f, ensure_ascii=False, indent=1)
            os.replace(tmp, QUOTA)


# ---------------------------------------------------------------- 自测

def selftest() -> None:
    import contextlib
    import io
    import socket
    import struct
    import tempfile
    from unittest.mock import patch
    global DIR, CALLS, QUOTA, PROXY_CONF
    DIR = tempfile.mkdtemp(prefix="vibegauge-selftest-")
    CALLS, QUOTA = os.path.join(DIR, "api-calls.jsonl"), os.path.join(DIR, "api-quota.json")
    PROXY_CONF = os.path.join(DIR, "proxy.json")

    def set_proxy_conf(conf: Dict[str, Any]) -> None:
        with open(PROXY_CONF, "w", encoding="utf-8") as f:
            json.dump(conf, f)
        _proxy_cache["at"] = 0.0
    set_proxy_conf({"upstream": "direct"})     # 自测结果不能取决于跑测试那台机器开没开系统代理
    _neg: Dict[str, Any] = {}
    _set(_neg, "out", -5); _set(_neg, "ctx", float("nan"))
    assert _neg == {}, _neg                      # 负数 / NaN 不记账

    responses_json = {"object": "response", "model": "responses-test", "status": "completed",
                      "usage": {"input_tokens": 100, "input_tokens_details": {"cached_tokens": 60},
                                "output_tokens": 20, "output_tokens_details": {"reasoning_tokens": 4}}}
    gemini_json = {"modelVersion": "gemini-test", "usageMetadata": {
        "promptTokenCount": 100, "cachedContentTokenCount": 60, "candidatesTokenCount": 20,
        "thoughtsTokenCount": 30, "totalTokenCount": 150}}
    initial_event = (b'data: {"type":"message_start","message":{"model":"glm-4.7",'
                     b'"usage":{"input_tokens":10,"output_tokens":1}}}\n\n')
    final_event = b'data: {"type":"message_delta","usage":{"output_tokens":999}}\n\n'
    text_event = b'data: {"type":"content_block_delta","delta":{"text":"' + b"x" * 32768 + b'"}}\n\n'
    large_size = len(initial_event) + 270 * len(text_event) + len(final_event)
    assert large_size > 8 * 1024 * 1024
    disconnect_release = threading.Event()
    disconnect_done = threading.Event()

    class Mock(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def log_message(self, *a): pass

        def send_json(self, obj):
            data = json.dumps(obj).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def send_sse(self, chunks, encoding="", truncated=False):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            if encoding:
                self.send_header("Content-Encoding", encoding)
            self.end_headers()
            for data in chunks:
                self.wfile.write(b"%x\r\n" % len(data) + data + b"\r\n")
                self.wfile.flush()
            if truncated:
                self.close_connection = True
            else:
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()

        def do_GET(self):
            # 用真实本地 HTTP 响应驱动 probe_kimi_code 的 ISO 重置时间解析。
            self.send_json({"usage": {"limit": 100, "used": 25, "resetTime": self.path[1:]}})

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            j = json.loads(body)
            if self.path == "/v1/responses":
                if j.get("stream"):
                    event = ("event: response.completed\r\ndata: " + json.dumps({
                        "type": "response.completed", "response": responses_json}) + "\r\n\r\n").encode()
                    # 每个字节一个 HTTP chunk，覆盖字段与 CRLF 被 read1 拆开的边界。
                    self.send_sse((event[i:i + 1] for i in range(len(event))))
                else:
                    self.send_json(responses_json)
                return
            if self.path == "/v1beta/models/gemini-test:generateContent":
                self.send_json(gemini_json)
                return
            if self.path == "/v1beta/models/gemini-test:streamGenerateContent":
                event = ("data: " + json.dumps(gemini_json) + "\n\n").encode()
                self.send_sse([event, event])  # 累计快照重复出现也只记一次
                return
            if self.path in ("/large-sse", "/large-gzip-sse"):
                def events():
                    yield initial_event
                    for _ in range(270):
                        yield text_event
                    yield final_event
                if self.path == "/large-gzip-sse":
                    def compressed():
                        compressor = zlib.compressobj(wbits=16 + zlib.MAX_WBITS)
                        for event in events():
                            data = compressor.compress(event)
                            if data:
                                yield data
                        yield compressor.flush()
                    self.send_sse(compressed(), encoding="gzip")
                else:
                    self.send_sse(events())
                return
            if self.path == "/upstream-broken-chunk":
                self.send_sse([initial_event], truncated=True)
                return
            if self.path == "/upstream-short-body":
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(len(initial_event) + 500))
                self.end_headers()
                self.wfile.write(initial_event)
                self.wfile.flush()
                self.close_connection = True
                return
            if self.path == "/missing-final-usage":
                self.send_sse([initial_event])
                return
            if self.path == "/oversized-event":
                self.send_sse([initial_event, b'data: {"text":"',
                               b"x" * UsageParser.EVENT_LIMIT, b'"}\n\n', final_event])
                return
            if self.path == "/client-disconnect":
                def interrupted_events():
                    yield initial_event
                    assert disconnect_release.wait(5), "客户端断开用例未释放 mock"
                    for _ in range(270):
                        yield text_event
                    yield final_event
                try:
                    self.send_sse(interrupted_events())
                except (BrokenPipeError, ConnectionResetError):
                    pass  # 客户端主动断开后，代理关闭上游连接是本用例的预期行为
                finally:
                    self.close_connection = True
                    disconnect_done.set()
                return
            if self.path == "/api/anthropic/v1/messages" and j.get("stream"):
                events = [
                    'event: message_start\ndata: {"type":"message_start","message":{"model":"glm-4.7","usage":{"input_tokens":10,"cache_read_input_tokens":5,"cache_creation_input_tokens":2,"output_tokens":1}}}\n\n',
                    'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}\n\n',
                    'event: message_delta\ndata: {"type":"message_delta","usage":{"output_tokens":7}}\n\n',
                ]
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                for e in events:
                    d = e.encode()
                    self.wfile.write(b"%x\r\n" % len(d) + d + b"\r\n")
                    self.wfile.flush()
                    time.sleep(0.05)
                self.wfile.write(b"0\r\n\r\n")
            else:
                data = json.dumps({"id": "x", "model": "deepseek-chat", "choices": [],
                                   "usage": {"prompt_tokens": 100, "completion_tokens": 20,
                                             "prompt_tokens_details": {"cached_tokens": 60},
                                             "completion_tokens_details": {"reasoning_tokens": 4}}}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                # 限流头：被动记账要能把它们抓下来（各家写法不同，这里用 OpenAI 那种）
                self.send_header("x-ratelimit-limit-requests", "500")
                self.send_header("x-ratelimit-remaining-requests", "125")
                self.send_header("x-ratelimit-reset-requests", "6m0s")
                self.send_header("x-request-id", "should-not-be-captured")
                self.end_headers()
                self.wfile.write(data)

    mock = ThreadingHTTPServer(("127.0.0.1", 0), Mock)
    mport = mock.server_address[1]
    threading.Thread(target=mock.serve_forever, daemon=True).start()
    # 上游代理：选路规则 + 经 HTTP 代理 CONNECT 隧道的真实往返（带 Basic 认证）
    tunnel_seen = []
    tsock = socket.socket(); tsock.bind(("127.0.0.1", 0)); tsock.listen(4)
    tport = tsock.getsockname()[1]

    def tunnel_serve() -> None:
        while True:
            try:
                cli, _ = tsock.accept()
            except OSError:
                return
            head = b""
            while b"\r\n\r\n" not in head:
                chunk = cli.recv(4096)
                if not chunk:
                    break
                head += chunk
            tunnel_seen.append(head.decode("latin-1"))
            target = head.split(b" ")[1].decode()
            up = socket.create_connection((target.rsplit(":", 1)[0], int(target.rsplit(":", 1)[1])))
            cli.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")

            def pipe(a, b):
                try:
                    while True:
                        d = a.recv(65536)
                        if not d:
                            break
                        b.sendall(d)
                except OSError:
                    pass
                finally:
                    for s in (a, b):
                        try:
                            s.shutdown(socket.SHUT_RDWR)
                        except OSError:
                            pass
            threading.Thread(target=pipe, args=(cli, up), daemon=True).start()
            threading.Thread(target=pipe, args=(up, cli), daemon=True).start()
    threading.Thread(target=tunnel_serve, daemon=True).start()

    purl = "http://u:p@127.0.0.1:%d" % tport
    with patch.dict(os.environ, {"VIBEGAUGE_UPSTREAM_PROXY": "http://env.example:1"}):
        set_proxy_conf({"upstream": purl, "no_proxy": ["skip.example"]})
        assert pick_proxy("https", "api.example.com") == purl                 # proxy.json 优先于环境变量
        assert pick_proxy("https", "a.skip.example") is None                  # no_proxy 后缀匹配
        assert all(pick_proxy("https", h) is None for h in ("127.0.0.1", "localhost", "::1"))   # 回环永远直连
        set_proxy_conf({"upstream": "socks5://127.0.0.1:1080"})
        assert pick_proxy("https", "api.example.com") is None                 # 只支持 http:// 代理
        set_proxy_conf({})
        assert pick_proxy("https", "api.example.com") == "http://env.example:1"   # 没配 proxy.json 退到环境变量
    assert redact_proxy(purl) == "http://127.0.0.1:%d (auth)" % tport and redact_proxy(None) == "direct"
    tc = open_upstream("http", "127.0.0.1:%d" % mport, 10, purl)
    tc.request("GET", "/2030-01-01T00:00:00Z")
    tr = tc.getresponse(); tbody = tr.read(); tc.close()
    assert tr.status == 200 and json.loads(tbody)["usage"]["used"] == 25, tbody
    assert tunnel_seen and tunnel_seen[0].startswith("CONNECT 127.0.0.1:%d " % mport), tunnel_seen
    assert "Proxy-Authorization: Basic dTpw" in tunnel_seen[0], tunnel_seen[0]
    tsock.close()
    set_proxy_conf({"upstream": "direct"})

    proxy = ProxyServer(("127.0.0.1", 0), Handler)
    pport = proxy.server_address[1]
    threading.Thread(target=proxy.serve_forever, daemon=True).start()

    c = http.client.HTTPConnection("127.0.0.1", pport, timeout=10)
    c.request("POST", "/http://127.0.0.1:%d/api/anthropic/v1/messages" % mport,
              body=json.dumps({"model": "glm-4.7", "stream": True, "messages": []}),
              headers={"Content-Type": "application/json", "x-api-key": "test-key"})
    r = c.getresponse()
    sse = r.read().decode()
    assert r.status == 200 and "message_delta" in sse, sse
    c.request("POST", "/http://127.0.0.1:%d/v1/chat/completions" % mport,
              body=json.dumps({"model": "deepseek-chat", "messages": []}),
              headers={"Content-Type": "application/json", "Authorization": "Bearer test"})
    r = c.getresponse()
    assert r.status == 200 and json.loads(r.read())["usage"]["prompt_tokens"] == 100
    c.request("GET", "/_vibegauge/health")
    h = json.loads(c.getresponse().read())
    assert h["ok"] and h["calls"] == 2 and h["parsed"] == 2, h
    c.request("GET", "/nonsense")
    r = c.getresponse()
    assert r.status == 400
    r.read()

    # Node fetch 只带 sec-fetch-mode：必须放行，否则 Node 系 CLI 经代理全挂
    # 用不记账的健康检查测放行，免得多出一次调用把后面的计数断言弄坏
    c.request("GET", "/_vibegauge/health", headers={"sec-fetch-mode": "cors"})
    r = c.getresponse()
    assert r.status == 200, "Node fetch 的 sec-fetch-mode 被误拦: %d" % r.status
    r.read()
    c.close()
    for headers in ({"Origin": "https://example.test"}, {"Origin": ""}, {"sEc-FeTcH-SiTe": "cross-site"},
                    {"Sec-Fetch-Dest": "empty"},
                    {"Host": "example.test:%d" % pport}, {"Host": "127.0.0.1:1"}):
        c.request("POST", "/http://127.0.0.1:%d/v1/chat/completions" % mport, body="{}", headers=headers)
        r = c.getresponse()
        assert r.status == 403, headers
        r.read()
        c.close()
    for hosts in ([], ["127.0.0.1:%d" % pport, "example.test:%d" % pport]):
        c.putrequest("GET", "/_vibegauge/health", skip_host=True)
        for host in hosts:
            c.putheader("Host", host)
        c.endheaders()
        r = c.getresponse()
        assert r.status == 403
        r.read()
        c.close()
    c.request("GET", "/_vibegauge/health", headers={"Host": "localhost:%d" % pport})
    r = c.getresponse()
    assert r.status == 200 and json.loads(r.read())["calls"] == 2
    c.close()

    fake_key = "AIzaFAKE" + "x" * 32
    # 原始 socket 才能把控制字符送到代理，http.client 自己会先拦住这条回归用例。
    with socket.create_connection(("127.0.0.1", pport), timeout=10) as sock:
        path = "/http://127.0.0.1:%d/v1/messages?key=%s\x01" % (mport, fake_key)
        sock.sendall(("POST %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" % (path, pport)).encode())
        r = http.client.HTTPResponse(sock)
        r.begin()
        error_body = r.read().decode()
        assert r.status == 502 and json.loads(error_body)["error"] == "vibegauge-proxy upstream error: InvalidURL", error_body
        assert "AIzaFAKE" not in error_body

    assert redact_path("/v1beta/models/gemini-3-pro:generateContent?key=AIzaSECRET") == "/v1beta/models/gemini-3-pro:generateContent?…"
    assert redact_path("/v1/messages") == "/v1/messages"
    assert redact_text("bad '/v1/messages?key=%s' suffix" % fake_key) == "bad '/v1/messages?…' suffix"
    for token in ("sk-FAKEabcdef", "sk-ant-FAKEabcdef", "sk-or-FAKEabcdef", "ark-FAKEabcdef", fake_key,
                  "0123456789abcdef" * 2, "Ab9+/cdE" * 4, "Ab9_-cdE" * 4):
        assert redact_text(token) == token[:4] + "…", token
    for label in ("Bearer ", "key=", "token=", "TOKEN='", "Key=\""):
        assert redact_text(label + "FAKEabcdef") == label + "FAKE…", label
    assert host_matches("deepseek.com", "deepseek.com")
    assert host_matches("API.DeepSeek.com:443", "deepseek.com")
    assert not host_matches("deepseek.com.gateway.example:443", "deepseek.com")
    assert not host_matches("notdeepseek.com", "deepseek.com")
    with patch.object(http.client, "HTTPSConnection") as connection:
        response = connection.return_value.getresponse.return_value
        response.status = 401
        response.read.return_value = ("bad key=" + fake_key).encode()
        try:
            _get_json("example.test", "/quota", {})
            assert False, "上游错误必须抛出异常"
        except RuntimeError as e:
            assert "AIzaFAKE" not in str(e) and "HTTP 401" in str(e)
    with contextlib.redirect_stderr(io.StringIO()) as captured:
        try:
            raise ValueError("bad token=" + fake_key)
        except ValueError:
            proxy.handle_error(None, None)
    assert "ValueError" in captured.getvalue() and "AIzaFAKE" not in captured.getvalue()

    # 既验证新建权限，也验证下次写入会修复旧文件的宽松权限。
    os.chmod(DIR, 0o755)
    os.chmod(CALLS, 0o644)
    append_call({"selftest": True})
    assert os.stat(DIR).st_mode & 0o777 == 0o700
    assert os.stat(CALLS).st_mode & 0o777 == 0o600
    for path in (QUOTA + ".tmp", os.path.join(DIR, "proxy.log")):
        with open(path, "w", encoding="utf-8", opener=private_opener) as f:
            f.write("{}")
        assert os.stat(path).st_mode & 0o777 == 0o600
        os.chmod(path, 0o644)
        with open(path, "a", encoding="utf-8", opener=private_opener):
            pass
        assert os.stat(path).st_mode & 0o777 == 0o600
    with open(QUOTA, "w", encoding="utf-8") as f:
        f.write("{}")
    os.chmod(QUOTA, 0o644)
    os.replace(QUOTA + ".tmp", QUOTA)
    assert os.stat(QUOTA).st_mode & 0o777 == 0o600

    recs = [json.loads(l) for l in open(CALLS, encoding="utf-8")]
    a, o = recs[0], recs[1]
    assert len(recs) == 4 and recs[2]["status"] == 502, recs
    assert "AIzaFAKE" not in recs[2]["error"] and "?…" in recs[2]["error"], recs[2]
    assert a["provider"] == "本地" and a["model"] == "glm-4.7" and a["stream"] is True
    assert a["ctx"] == 17 and a["cache_read"] == 5 and a["cache_write"] == 2 and a["out"] == 7 and a["parsed"], a
    assert o["ctx"] == 100 and o["cache_read"] == 60 and o["out"] == 20 and o["think"] == 4 and o["parsed"], o
    assert o.get("rl") == {"x-ratelimit-limit-requests": "500", "x-ratelimit-remaining-requests": "125",
                           "x-ratelimit-reset-requests": "6m0s"}, o.get("rl")     # 只收限流头，别的头不收
    assert "rl" not in a, "上游没给限流头就不该有这个字段"
    # 同一上游两个 key：各存一份，不再是后到的覆盖前一个（余额 / 套餐探针要各查各的账户）
    host_keys = {k: v for k, v in _keys.items() if k.startswith("127.0.0.1:%d#" % mport)}
    assert sorted(host_keys) == sorted("127.0.0.1:%d#%s" % (mport, key_fingerprint(v)) for v in ("test-key", "Bearer test")), host_keys
    assert host_keys["127.0.0.1:%d#%s" % (mport, key_fingerprint("Bearer test"))].get("authorization") == "Bearer test"

    def records():
        with _lock, open(CALLS, encoding="utf-8") as f:
            return [json.loads(line) for line in f]

    def await_record(previous, path):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            rows = records()
            if len(rows) > previous:
                assert len(rows) == previous + 1 and rows[-1]["path"] == path, rows
                return rows[-1]
            time.sleep(0.01)
        raise AssertionError("请求结束未记账: " + path)

    def call(path, stream=False, broken=False):
        previous = len(records())
        client = http.client.HTTPConnection("127.0.0.1", pport, timeout=10)
        client.request("POST", "/http://127.0.0.1:%d%s" % (mport, path),
                       body=json.dumps({"model": "request-model", "stream": stream}))
        response = client.getresponse()
        assert response.status == 200
        size = 0
        digest = hashlib.sha256()
        read_error = False
        try:
            while True:
                data = response.read(65536)
                if not data:
                    read_error = response.length not in (None, 0)
                    break
                size += len(data)
                digest.update(data)
        except http.client.IncompleteRead:
            read_error = True
        finally:
            client.close()
        assert read_error == broken, (path, read_error)
        return await_record(previous, path), size, digest.hexdigest()

    # Responses 的整包/完成事件：缓存与思考明细正确，out 不重复加 think。
    for stream in (False, True):
        rec, _, _ = call("/v1/responses", stream)
        assert rec["model"] == "responses-test" and rec["ctx"] == 100 and rec["cache_read"] == 60, rec
        assert rec["out"] == 20 and rec["think"] == 4 and rec["parsed"] and rec["complete"], rec
        assert "error" not in rec, rec
    # Gemini 输出总量包含思考；重复流式累计快照不得翻倍。
    for method in ("generateContent", "streamGenerateContent"):
        rec, _, _ = call("/v1beta/models/gemini-test:" + method, method.startswith("stream"))
        assert rec["model"] == "gemini-test" and rec["ctx"] == 100 and rec["cache_read"] == 60, rec
        assert rec["out"] == 50 and rec["think"] == 30 and rec["parsed"] and "error" not in rec, rec
    # 上面的原有 Chat Completions 用例仍断言 out=20、think=4，不能变成 24。

    expected_digest = hashlib.sha256(initial_event)
    for _ in range(270):
        expected_digest.update(text_event)
    expected_digest.update(final_event)
    rec, size, digest = call("/large-sse", True)
    assert size == large_size and rec["bytes"] == large_size and digest == expected_digest.hexdigest(), rec
    assert rec["ctx"] == 10 and rec["out"] == 999 and rec["parsed"] and "error" not in rec, rec
    rec, _, _ = call("/large-gzip-sse", True)
    assert rec["ctx"] == 10 and rec["out"] == 999 and rec["parsed"] and "error" not in rec, rec

    # read1 抛异常及 Content-Length 提前 EOF：各自记一条，保留部分量并标错。
    for path in ("/upstream-broken-chunk", "/upstream-short-body"):
        rec, _, _ = call(path, True, broken=True)
        assert rec["status"] == 200 and rec["out"] == 1 and rec["ctx"] == 10, rec
        assert not rec["parsed"] and not rec["complete"] and rec["error"] == "upstream_error: IncompleteRead", rec
    rec, _, _ = call("/missing-final-usage", True)
    assert not rec["parsed"] and rec["out"] == 1 and rec["error"] == "final_usage_not_found", rec
    rec, _, _ = call("/oversized-event", True)
    assert not rec["parsed"] and rec["out"] == 999 and rec["error"] == "sse_event_too_large", rec

    # 真实客户端在初始 usage 后 RST 断开，mock 随后继续发，验证写失败也只记一次。
    previous = len(records())
    with socket.create_connection(("127.0.0.1", pport), timeout=10) as sock:
        body = b'{"stream":true}'
        sock.sendall(("POST /http://127.0.0.1:%d/client-disconnect HTTP/1.1\r\n"
                      "Host: 127.0.0.1:%d\r\nContent-Length: %d\r\n\r\n" % (mport, pport, len(body))).encode() + body)
        response = http.client.HTTPResponse(sock)
        response.begin()
        assert response.status == 200 and response.read(len(initial_event)) == initial_event
        response.close()
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    disconnect_release.set()
    rec = await_record(previous, "/client-disconnect")
    assert not rec["parsed"] and not rec["complete"] and rec["error"].startswith("client_error:"), rec
    assert rec["ctx"] == 10 and rec["out"] == 1, rec
    assert disconnect_done.wait(5), "客户端断开后，上游连接没有关闭"

    # 分块、多行 data、UTF-8、CR/LF、gzip，以及有界缓存的确定性边界检查。
    multiline = ('event: response.completed\r\ndata: {"type":"response.completed",\r\n'
                 'data: "response":' + json.dumps(dict(responses_json, model="测试模型"), ensure_ascii=False)
                 + '}\r\n\r\n').encode()
    for payload, encoding in ((multiline, ""), (gzip.compress(multiline), "gzip")):
        parser = UsageParser(None, "text/event-stream", encoding)
        for value in payload:
            parser.feed(bytes([value]))
        u = parser.finish()
        assert u["model"] == "测试模型" and u["out"] == 20 and u["parsed"], u
    parser = UsageParser(None, "text/event-stream", "")
    parser.feed(b'data: {"text":"')
    for _ in range(270):
        parser.feed(b"x" * 65536)
        assert len(parser.buf) <= parser.EVENT_LIMIT and len(parser.event) <= parser.EVENT_LIMIT
    parser.feed(b'"}\n\n' + final_event)
    u = parser.finish()
    assert u["out"] == 999 and not u["parsed"] and u["error"] == "sse_event_too_large", u
    u = parse_usage(None, "text/event-stream", initial_event + final_event[:-2], "")
    assert not u["parsed"] and u["error"] == "incomplete_sse_event", u
    u = parse_usage(None, "text/event-stream", gzip.compress(initial_event + final_event)[:-8], "gzip")
    assert not u["parsed"] and u["error"] == "incomplete_gzip", u

    def local_quota(host, path, headers):
        client = http.client.HTTPConnection("127.0.0.1", mport, timeout=10)
        try:
            client.request("GET", "/" + reset_time)
            return json.loads(client.getresponse().read())
        finally:
            client.close()

    # 同一 epoch 的 Z / 正负偏移 / 无时区值，在 UTC 和非 UTC 的本机时区均相同。
    for tz in ("UTC0", "EST5EDT"):
        try:
            with patch.dict(os.environ, {"TZ": tz}):
                time.tzset()
                for reset_time, expected in (("2024-01-01T00:00:00Z", 1704067200),
                                             ("2024-01-01T08:00:00+08:00", 1704067200),
                                             ("2023-12-31T19:00:00-05:00", 1704067200),
                                             ("2024-01-01T00:00:00", 1704067200),
                                             ("2024-01-01T08:00:00.125+08:00", 1704067200.125)):
                    with patch(__name__ + "._get_json", side_effect=local_quota):
                        quota = probe_kimi_code({})
                    assert quota["windows"]["5h"]["resets_at"] == expected, (tz, reset_time, quota)
        finally:
            time.tzset()
    assert _iso_to_s(None) is None and _iso_to_s("not-a-date") is None
    assert _iso_to_s("2024-01-01 00:00:00") == 1704067200
    rows = records()
    assert _stats["calls"] == len(rows) - 1, (rows, _stats)  # 排除权限测试的手工记录
    assert _stats["parsed"] == sum(bool(row.get("parsed")) for row in rows), _stats
    assert _stats["errors"] == sum(row.get("status", 0) >= 400 or not row.get("complete", True) for row in rows), _stats
    # sent：连不上上游（URL 非法 / 拒连）的请求没到厂商；解析成功的一定已发出
    assert any(row.get("sent") is False and row.get("status") == 502 for row in rows), rows
    assert all(row.get("sent") is True for row in rows if row.get("parsed")), rows
    with open(CALLS, encoding="utf-8") as f:
        ledger = f.read()
    assert "x" * 100 not in ledger and "test-key" not in ledger and '"usage"' not in ledger, "正文/凭据不得落盘"
    print("selftest OK: 上游代理隧道 + Responses + Gemini 思考量 + >8MiB SSE/gzip + 流中断/客户端断开 + 时区 + 原有回归, 记录", CALLS)
    # 先停服务线程再退出：否则守护线程在解释器收尾时还握着 stderr 锁，
    # 会报 "Fatal Python error: _enter_buffered_busy"、退出码 134，CI 就红了（断言其实全过）
    proxy.shutdown(); mock.shutdown()
    proxy.server_close(); mock.server_close()
    sys.stdout.flush(); sys.stderr.flush()


def main() -> None:
    sys.excepthook = log_exception
    threading.excepthook = lambda args: log_exception(args.exc_type, args.exc_value, args.exc_traceback)
    if "--selftest" in sys.argv:
        selftest()
        return
    ensure_dir()
    with open(os.path.join(DIR, "proxy.log"), "a", encoding="utf-8", opener=private_opener):
        pass
    threading.Thread(target=quota_loop, daemon=True).start()
    srv = ProxyServer(("127.0.0.1", PORT), Handler)
    srv.daemon_threads = True
    print("vibegauge-proxy listening on 127.0.0.1:%d, dir=%s" % (PORT, DIR), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
