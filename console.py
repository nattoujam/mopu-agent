#!/usr/bin/env python3
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime
from fcntl import LOCK_EX, LOCK_NB, LOCK_UN, flock
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

AGENT_DIR = Path(os.environ.get("AGENT_DIR") or Path(__file__).resolve().parent)
STATE_DIR = AGENT_DIR / "state"
LOGS_DIR = AGENT_DIR / "logs"
RUN_LOG_DIR = LOGS_DIR / "console"
WEB_DIR = AGENT_DIR / "web"
CONSOLE_STATE = STATE_DIR / "console.json"
RUNS_FILE = STATE_DIR / "console-runs.jsonl"
SPEND_FILE = STATE_DIR / "spend.jsonl"
LAST_POLL_FILE = STATE_DIR / "last-poll"
POLL_LOCK = STATE_DIR / "poll.lock"

# 60秒未満はポーリングというより連打で、gh のレート上限と利用枠を無駄に削る
MIN_INTERVAL = 60
MAX_INTERVAL = 86400
RUNS_KEEP = 200
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
ANSI_RE = re.compile(r"\x1b\[([0-9;]*)m")
DURATION_RE = re.compile(r"^\s*(\d+)\s*([smh]?)\s*$", re.IGNORECASE)


def log(msg):
    print(f"{datetime.now():%H:%M:%S} [console] {msg}", file=sys.stderr, flush=True)


def parse_duration(value):
    if isinstance(value, bool):
        raise ValueError("間隔が数値ではありません")
    if isinstance(value, (int, float)):
        return int(value)
    m = DURATION_RE.match(str(value))
    if not m:
        raise ValueError(f"間隔を解釈できません: {value}")
    unit = (m.group(2) or "s").lower()
    return int(m.group(1)) * {"s": 1, "m": 60, "h": 3600}[unit]


def clamp_interval(seconds):
    return max(MIN_INTERVAL, min(MAX_INTERVAL, int(seconds)))


def read_text(path, limit=None):
    try:
        with path.open("rb") as fh:
            if limit is not None:
                size = fh.seek(0, 2)
                fh.seek(max(0, size - limit))
            return fh.read().decode("utf-8", "replace")
    except OSError:
        return ""


def poll_lock_held():
    try:
        fd = os.open(POLL_LOCK, os.O_RDWR | os.O_CREAT, 0o644)
    except OSError:
        return False
    try:
        flock(fd, LOCK_EX | LOCK_NB)
        flock(fd, LOCK_UN)
        return False
    except OSError:
        return True
    finally:
        os.close(fd)


def spend_summary():
    total = 0.0
    count = 0
    last = None
    for line in read_text(SPEND_FILE).splitlines():
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        total += float(entry.get("cost_usd") or 0)
        count += 1
        last = entry
    return {
        "total_usd": round(total, 4),
        "tasks": count,
        "last_task": (last or {}).get("task"),
        "last_time": (last or {}).get("time"),
        "pct_5h": (last or {}).get("pct_5h_after"),
    }


def strip_ansi_lines(text):
    lines = []
    for raw in text.splitlines():
        level = "info"
        for code in ANSI_RE.findall(raw):
            if "33" in code.split(";"):
                level = "warn"
            elif "31" in code.split(";"):
                level = "error"
        lines.append({"text": ANSI_RE.sub("", raw), "level": level})
    return lines


def summarize_run_log(path):
    text = read_text(path, limit=256 * 1024)
    plain = ANSI_RE.sub("", text)
    # git を引き直さずログから拾う。コンソールが読む時点では作業ツリーが
    # 変わっているかもしれず、その実行が名乗った SHA と食い違うため
    commit = re.search(r"mopu-agent (\S+)", plain)
    found = re.search(r"(\d+)\s*件のタスクを検出", plain)
    done = re.search(r"完了:\s*(\d+)\s*件", plain)
    idle = "処理するタスクはありません" in plain
    return {
        "commit": commit.group(1) if commit else None,
        "detected": int(found.group(1)) if found else (0 if idle else None),
        "processed": int(done.group(1)) if done else None,
        "warnings": sum(1 for m in ANSI_RE.finditer(text) if "33" in m.group(1).split(";")),
        "errors": sum(1 for m in ANSI_RE.finditer(text) if "31" in m.group(1).split(";")),
    }


def load_console_state():
    default_interval = clamp_interval(parse_duration(os.environ.get("CONSOLE_INTERVAL") or 300))
    state = {"interval_seconds": default_interval, "enabled": True}
    try:
        saved = json.loads(CONSOLE_STATE.read_text())
        if isinstance(saved.get("interval_seconds"), (int, float)):
            state["interval_seconds"] = clamp_interval(saved["interval_seconds"])
        if isinstance(saved.get("enabled"), bool):
            state["enabled"] = saved["enabled"]
    except (OSError, ValueError):
        pass
    return state


def save_console_state(state):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = CONSOLE_STATE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False))
    tmp.replace(CONSOLE_STATE)


class Scheduler:
    def __init__(self):
        state = load_console_state()
        self.interval = state["interval_seconds"]
        self.enabled = state["enabled"]
        self.lock = threading.Lock()
        self.wake = threading.Event()
        self.stopping = threading.Event()
        self.current = None
        self.proc = None
        self.manual_requested = False
        self.manual_retry = None
        self.runs = self._load_runs()
        self.next_run_at = time.time() + self.interval if self.enabled else None
        self.thread = threading.Thread(target=self._loop, daemon=True)

    def _load_runs(self):
        runs = []
        for line in read_text(RUNS_FILE).splitlines():
            try:
                runs.append(json.loads(line))
            except ValueError:
                continue
        return runs[-RUNS_KEEP:][::-1]

    def start(self):
        self.thread.start()

    def snapshot(self):
        with self.lock:
            return {
                "enabled": self.enabled,
                "interval_seconds": self.interval,
                "next_run_at": self.next_run_at,
                "current": dict(self.current) if self.current else None,
                "runs": [dict(r) for r in self.runs[:50]],
            }

    def update(self, interval=None, enabled=None):
        with self.lock:
            if interval is not None:
                self.interval = clamp_interval(interval)
            if enabled is not None:
                self.enabled = bool(enabled)
            if not self.enabled:
                self.next_run_at = None
            else:
                self.next_run_at = time.time() + self.interval
            save_console_state({"interval_seconds": self.interval, "enabled": self.enabled})
        self.wake.set()

    def request_run(self, retry_number=None):
        with self.lock:
            if self.current is not None:
                return False
            self.manual_requested = True
            self.manual_retry = retry_number
        self.wake.set()
        return True

    def stop(self):
        self.stopping.set()
        self.wake.set()

    def _loop(self):
        while not self.stopping.is_set():
            trigger = retry_number = None
            with self.lock:
                if self.manual_requested:
                    self.manual_requested = False
                    retry_number = self.manual_retry
                    self.manual_retry = None
                    trigger = "retry" if retry_number else "manual"
                elif self.enabled and self.next_run_at and time.time() >= self.next_run_at:
                    trigger = "schedule"
            if trigger:
                self._execute(trigger, retry_number)
                with self.lock:
                    self.next_run_at = time.time() + self.interval if self.enabled else None
                continue
            self.wake.wait(1.0)
            self.wake.clear()

    def _execute(self, trigger, retry_number=None):
        argv = [str(AGENT_DIR / "poll.sh")]
        if retry_number:
            argv += ["--retry", str(retry_number)]
        RUN_LOG_DIR.mkdir(parents=True, exist_ok=True)
        name = f"poll-{datetime.now():%Y%m%d-%H%M%S}.log"
        path = RUN_LOG_DIR / name
        started = time.time()
        with self.lock:
            self.current = {"log": name, "trigger": trigger, "started_at": started, "retry_number": retry_number}
        exit_code = None
        try:
            with path.open("wb") as fh:
                proc = subprocess.Popen(
                    argv,
                    cwd=str(AGENT_DIR),
                    stdin=subprocess.DEVNULL,
                    stdout=fh,
                    stderr=subprocess.STDOUT,
                    start_new_session=True,
                )
                with self.lock:
                    self.proc = proc
                exit_code = proc.wait()
        except OSError as exc:
            with path.open("a", encoding="utf-8") as fh:
                fh.write(f"poll.sh を起動できませんでした: {exc}\n")
            exit_code = -1
        finally:
            with self.lock:
                self.proc = None
        record = {
            "log": name,
            "trigger": trigger,
            "retry_number": retry_number,
            "started_at": started,
            "finished_at": time.time(),
            "duration_s": round(time.time() - started, 1),
            "exit_code": exit_code,
        }
        record.update(summarize_run_log(path))
        try:
            with RUNS_FILE.open("a", encoding="utf-8") as fh:
                fh.write(json.dumps(record, ensure_ascii=False) + "\n")
        except OSError as exc:
            log(f"実行履歴を書けませんでした: {exc}")
        with self.lock:
            self.current = None
            self.runs.insert(0, record)
            del self.runs[RUNS_KEEP:]
        log(f"ポーリング終了 ({trigger}) exit={exit_code} {record['duration_s']}s")

    def wait_for_current(self, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.lock:
                if self.current is None:
                    return True
            time.sleep(0.5)
        return False


_task_cache = {}


def task_ids():
    if not LOGS_DIR.is_dir():
        return []
    dirs = [d for d in LOGS_DIR.iterdir() if d.is_dir() and d.name != "console"]
    return sorted(dirs, key=lambda d: d.name.rsplit("-", 2)[-2:], reverse=True)


def task_summary(path):
    stream = path / "stream.jsonl"
    try:
        stat = stream.stat()
        key = (stat.st_mtime_ns, stat.st_size)
    except OSError:
        key = None
    cached = _task_cache.get(path.name)
    if cached and cached[0] == key:
        return cached[1]

    summary = {"id": path.name, "state": "unknown"}
    m = re.match(r"^(issue|comment)-(\d+)-(\d{8})-(\d{6})$", path.name)
    if m:
        summary["kind"] = m.group(1)
        summary["number"] = int(m.group(2))
        summary["started_at"] = datetime.strptime(m.group(3) + m.group(4), "%Y%m%d%H%M%S").timestamp()
    for line in reversed(read_text(stream, limit=512 * 1024).splitlines()):
        if '"type":"result"' not in line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if obj.get("type") != "result":
            continue
        summary["state"] = "error" if obj.get("is_error") else "success"
        summary["subtype"] = obj.get("subtype")
        summary["cost_usd"] = obj.get("total_cost_usd")
        summary["duration_ms"] = obj.get("duration_ms")
        summary["turns"] = obj.get("num_turns")
        summary["result"] = (obj.get("result") or "")[:400]
        break
    else:
        # stream.jsonl が無いのはエージェントを起動する前に打ち切られたとき
        # （依存の準備の失敗、worktree の準備の失敗）
        summary["state"] = "incomplete" if stream.exists() else "aborted"
    _task_cache[path.name] = (key, summary)
    return summary


def truncate(text, limit=800):
    text = str(text)
    return text if len(text) <= limit else text[:limit] + " …"


# ツールごとの「まず読みたい引数」。先頭に寄せて表示するためだけの並び順で、
# ここに無いツールはキーの元の順で出す
TOOL_PRIMARY_FIELD = {
    "Bash": "command",
    "Read": "file_path",
    "Write": "file_path",
    "Edit": "file_path",
    "NotebookEdit": "notebook_path",
    "Glob": "pattern",
    "Grep": "pattern",
    "Task": "description",
    "WebFetch": "url",
    "WebSearch": "query",
}


def tool_fields(data, name=""):
    if not isinstance(data, dict):
        return [["input", truncate(str(data or ""), 600)]]
    keys = list(data.keys())
    primary = TOOL_PRIMARY_FIELD.get(name)
    if primary in keys:
        keys.remove(primary)
        keys.insert(0, primary)
    fields = []
    for key in keys[:8]:
        value = data[key]
        # 元が JSON なので true/false/null は Python 表記に崩さず JSON 表記のまま出す
        if not isinstance(value, str):
            value = json.dumps(value, ensure_ascii=False)
        fields.append([key, truncate(value, 600)])
    return fields


def blocks_of(message):
    content = message.get("content")
    if isinstance(content, str):
        yield {"kind": "text", "text": content}
    elif isinstance(content, list):
        for block in content:
            if not isinstance(block, dict):
                continue
            btype = block.get("type")
            if btype == "text":
                yield {"kind": "text", "text": block.get("text", "")}
            elif btype == "thinking":
                yield {"kind": "thinking", "text": block.get("thinking", "")}
            elif btype == "tool_use":
                name = block.get("name", "?")
                yield {
                    "kind": "tool_use",
                    "name": name,
                    "text": "",
                    "fields": tool_fields(block.get("input"), name),
                }
            elif btype == "tool_result":
                body = block.get("content")
                if isinstance(body, list):
                    body = "".join(b.get("text", "") for b in body if isinstance(b, dict))
                yield {
                    "kind": "tool_result",
                    "text": str(body or ""),
                    "is_error": bool(block.get("is_error")),
                }


def system_text(subtype, obj):
    if subtype == "init":
        return " ".join(
            f"{k}={obj.get(k)}" for k in ("model", "permissionMode", "cwd") if obj.get(k)
        )
    if subtype == "permission_denied":
        return f"{obj.get('tool_name', '?')}: {obj.get('message') or obj.get('decision_reason') or ''}".strip()
    if subtype == "vcs_state_changed":
        return " ".join(f"{k}={obj.get(k)}" for k in ("kind", "branch") if obj.get(k))
    drop = {"type", "subtype", "uuid", "session_id"}
    return truncate(json.dumps({k: v for k, v in obj.items() if k not in drop}, ensure_ascii=False), 300)


def task_detail(path):
    events = []
    for lineno, line in enumerate(read_text(path / "stream.jsonl").splitlines(), 1):
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        etype = obj.get("type")
        if etype in ("assistant", "user"):
            for block in blocks_of(obj.get("message", {})):
                text = (block.get("text") or "").strip()
                if not text and block["kind"] != "tool_use":
                    continue
                events.append(
                    {
                        "line": lineno,
                        "role": etype,
                        "kind": block["kind"],
                        "name": block.get("name"),
                        "text": truncate(text),
                        "fields": block.get("fields"),
                        "is_error": block.get("is_error", False),
                    }
                )
        elif etype == "system":
            subtype = obj.get("subtype") or "system"
            if subtype == "thinking_tokens":
                continue
            events.append(
                {"line": lineno, "role": "system", "kind": subtype, "text": system_text(subtype, obj)}
            )
        elif etype == "result":
            events.append(
                {
                    "line": lineno,
                    "role": "result",
                    "kind": obj.get("subtype") or "result",
                    "text": truncate(obj.get("result") or ""),
                    "is_error": bool(obj.get("is_error")),
                }
            )
    return {
        "summary": task_summary(path),
        "events": events[-300:],
        "stderr": read_text(path / "stderr.log", limit=64 * 1024),
        "setup": read_text(path / "setup.log", limit=64 * 1024),
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "mopu-console"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, obj, code=200):
        self._send(code, json.dumps(obj, ensure_ascii=False))

    def _error(self, code, message):
        self._json({"error": message}, code)

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return {}
        return json.loads(self.rfile.read(length).decode("utf-8"))

    def do_GET(self):
        path = unquote(urlparse(self.path).path)
        if path in ("/", "/index.html"):
            page = WEB_DIR / "index.html"
            if not page.is_file():
                return self._error(500, "web/index.html がありません")
            return self._send(200, page.read_bytes(), "text/html; charset=utf-8")
        if path == "/api/status":
            return self._json(self._status())
        if path == "/api/tasks":
            return self._json({"tasks": [task_summary(d) for d in task_ids()[:100]]})
        if path.startswith("/api/runs/"):
            name = path[len("/api/runs/"):]
            if not ID_RE.match(name) or not name.endswith(".log"):
                return self._error(400, "不正なログ名です")
            target = RUN_LOG_DIR / name
            if not target.is_file():
                return self._error(404, "ログがありません")
            return self._json({"log": name, "lines": strip_ansi_lines(read_text(target, 512 * 1024))})
        if path.startswith("/api/tasks/") and path.endswith("/raw"):
            name = path[len("/api/tasks/"):-len("/raw")]
            if not ID_RE.match(name):
                return self._error(400, "不正なタスク ID です")
            target = LOGS_DIR / name
            if not target.is_dir() or name == "console":
                return self._error(404, "タスクログがありません")
            wanted = parse_qs(urlparse(self.path).query).get("line", [None])[0]
            if wanted is None:
                return self._json(
                    {
                        "stream": read_text(target / "stream.jsonl", 2 * 1024 * 1024),
                        "stderr": read_text(target / "stderr.log", 256 * 1024),
                        "setup": read_text(target / "setup.log", 256 * 1024),
                    }
                )
            try:
                lineno = int(wanted)
            except ValueError:
                return self._error(400, "line は整数で指定してください")
            lines = read_text(target / "stream.jsonl", 4 * 1024 * 1024).splitlines()
            if not 1 <= lineno <= len(lines):
                return self._error(404, f"{lineno} 行目はありません（全 {len(lines)} 行）")
            return self._json({"line": lineno, "text": lines[lineno - 1]})
        if path.startswith("/api/tasks/"):
            name = path[len("/api/tasks/"):]
            if not ID_RE.match(name):
                return self._error(400, "不正なタスク ID です")
            target = LOGS_DIR / name
            if not target.is_dir() or name == "console":
                return self._error(404, "タスクログがありません")
            return self._json(task_detail(target))
        return self._error(404, "not found")

    def do_POST(self):
        path = unquote(urlparse(self.path).path)
        try:
            body = self._body()
        except ValueError:
            return self._error(400, "JSON を解釈できません")
        if path == "/api/settings":
            interval = None
            if "interval" in body:
                try:
                    interval = parse_duration(body["interval"])
                except ValueError as exc:
                    return self._error(400, str(exc))
                if not MIN_INTERVAL <= interval <= MAX_INTERVAL:
                    return self._error(400, f"間隔は {MIN_INTERVAL}〜{MAX_INTERVAL} 秒の範囲で指定してください")
            enabled = body.get("enabled")
            if enabled is not None and not isinstance(enabled, bool):
                return self._error(400, "enabled は真偽値で指定してください")
            SCHEDULER.update(interval=interval, enabled=enabled)
            return self._json(self._status())
        if path == "/api/run":
            retry_number = None
            if body.get("retry") is not None:
                try:
                    retry_number = int(body["retry"])
                except (TypeError, ValueError):
                    return self._error(400, "retry は Issue 番号（整数）で指定してください")
                if retry_number < 1:
                    return self._error(400, "retry は 1 以上の整数で指定してください")
            if not SCHEDULER.request_run(retry_number):
                return self._error(409, "すでにポーリングが実行中です")
            return self._json(self._status())
        return self._error(404, "not found")

    def _status(self):
        status = SCHEDULER.snapshot()
        return {
            "now": time.time(),
            "repo": os.environ.get("REPO", ""),
            "scheduler": status,
            "poll": {
                "lock_held": poll_lock_held(),
                "last_poll_at": read_text(LAST_POLL_FILE).strip() or None,
            },
            "spend": spend_summary(),
            "limits": {"min_interval": MIN_INTERVAL, "max_interval": MAX_INTERVAL},
        }


SCHEDULER = Scheduler()


def _raise_interrupt(signum, frame):
    raise KeyboardInterrupt


def main():
    host = os.environ.get("CONSOLE_HOST") or "127.0.0.1"
    port = int(os.environ.get("CONSOLE_PORT") or 8787)
    # コンソールから poll.sh 越しにエージェントを起動できる = 実質的な任意コード実行
    if host not in ("127.0.0.1", "::1", "localhost") and os.environ.get("CONSOLE_ALLOW_REMOTE") != "1":
        log(f"{host} での待受は拒否します。認証がないため loopback 以外に晒すのは危険です")
        log("それでも公開する場合は CONSOLE_ALLOW_REMOTE=1 を設定し、前段で認証をかけてください")
        return 1

    if not (AGENT_DIR / "poll.sh").is_file():
        log(f"poll.sh が見つかりません: {AGENT_DIR}")
        return 1

    RUN_LOG_DIR.mkdir(parents=True, exist_ok=True)
    # 既定の SIGTERM は finally を通さずにプロセスを落とすため、実行中の poll.sh を
    # 待つ後始末が走らない。systemd stop で agent:running ラベルが残るのを避ける
    signal.signal(signal.SIGTERM, _raise_interrupt)
    SCHEDULER.start()
    server = ThreadingHTTPServer((host, port), Handler)
    server.daemon_threads = True
    log(f"http://{host}:{port} で待受")
    state = SCHEDULER.snapshot()
    if state["enabled"]:
        log(f"次回ポーリング: {state['interval_seconds']} 秒後")
    else:
        log("スケジューラは停止中です（コンソールから再開できます）")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()
        SCHEDULER.stop()
        if SCHEDULER.snapshot()["current"]:
            log("実行中のポーリングが終わるのを待っています (最大 5 分)")
            if not SCHEDULER.wait_for_current(300):
                log("待機を打ち切りました。poll.sh はバックグラウンドで継続します")
    return 0


if __name__ == "__main__":
    sys.exit(main())
