"""Protocol-loop tests. They never import torch or ACE-Step."""

from __future__ import annotations

import io
import json
import subprocess
import sys
import threading
import time

from clipper_worker.protocol import (
    FEATURE_NOT_INSTALLED,
    INVALID_PARAMS,
    METHOD_NOT_FOUND,
    PARSE_ERROR,
    REQUEST_CANCELLED,
    Server,
)


class LineSink(io.TextIOBase):
    """Collects written lines; thread-safe enough for the server's single write lock."""

    def __init__(self) -> None:
        self.buffer = ""
        self.changed = threading.Condition()

    def write(self, s: str) -> int:
        with self.changed:
            self.buffer += s
            self.changed.notify_all()
        return len(s)

    def messages(self) -> list[dict]:
        return [json.loads(line) for line in self.buffer.splitlines() if line]

    def wait_for(self, predicate, timeout: float = 5.0) -> list[dict]:
        deadline = time.monotonic() + timeout
        with self.changed:
            while not predicate(self.messages()):
                remaining = deadline - time.monotonic()
                assert remaining > 0, f"timed out; got {self.messages()}"
                self.changed.wait(remaining)
        return self.messages()


def request(id, method, params=None) -> str:
    msg = {"jsonrpc": "2.0", "id": id, "method": method}
    if params is not None:
        msg["params"] = params
    return json.dumps(msg)


def response(messages, id):
    return next((m for m in messages if m.get("id") == id and ("result" in m or "error" in m)), None)


def test_request_response_matching_and_errors():
    out = LineSink()
    handlers = {
        "echo": lambda p, ctx: p,
        "boom": lambda p, ctx: 1 / 0,
    }
    server = Server(handlers, out)
    server.handle_line(request(1, "echo", {"x": 1}))
    server.handle_line(request("two", "echo", {"y": [1, 2]}))
    server.handle_line(request(3, "nope"))
    server.handle_line(request(4, "boom"))
    server.handle_line(request(5, "echo", [1, 2]))
    server.handle_line("{not json")
    msgs = out.wait_for(lambda m: all(response(m, i) for i in (1, "two", 3, 4, 5)) and len(m) == 6)

    assert response(msgs, 1)["result"] == {"x": 1}
    assert response(msgs, "two")["result"] == {"y": [1, 2]}
    assert response(msgs, 3)["error"]["code"] == METHOD_NOT_FOUND
    assert "ZeroDivisionError" in response(msgs, 4)["error"]["message"]
    assert response(msgs, 5)["error"]["code"] == INVALID_PARAMS
    assert any(m.get("error", {}).get("code") == PARSE_ERROR and m["id"] is None for m in msgs)


def test_progress_and_cancel():
    out = LineSink()
    started = threading.Event()

    def slow(params, ctx):
        for i in range(500):
            ctx.check_cancelled()
            ctx.progress(i / 500, "working")
            started.set()
            time.sleep(0.01)
        return "finished"

    server = Server({"slow": slow, "echo": lambda p, ctx: p}, out)
    server.handle_line(request(7, "slow"))
    assert started.wait(5)
    # Other requests are answered while the slow one runs.
    server.handle_line(request(8, "echo", {"ok": True}))
    out.wait_for(lambda m: response(m, 8) is not None)
    server.handle_line(json.dumps({"jsonrpc": "2.0", "method": "$/cancel", "params": {"id": 7}}))
    msgs = out.wait_for(lambda m: response(m, 7) is not None)

    progress = [m for m in msgs if m.get("method") == "progress"]
    assert progress and all(p["params"]["id"] == 7 and 0 <= p["params"]["fraction"] <= 1 for p in progress)
    assert response(msgs, 7)["error"]["code"] == REQUEST_CANCELLED


def run_worker(lines: list[str], timeout: float = 30) -> tuple[list[dict], str]:
    proc = subprocess.run([sys.executable, "-m", "clipper_worker"], input="\n".join(lines) + "\n",
                          capture_output=True, text=True, timeout=timeout)
    return [json.loads(line) for line in proc.stdout.splitlines()], proc.stderr


def test_subprocess_ping_capabilities_and_clean_stdout():
    msgs, stderr = run_worker([
        request(1, "ping"),
        request(2, "capabilities"),
        # Invalid duration: rejected before any model is loaded, whether or not the music extra is installed.
        request(3, "generate_music", {"prompt": "x", "duration_s": 1, "out_path": "/tmp/x.wav"}),
    ])
    # Every stdout line is a protocol message; logs went to stderr.
    assert all(m.get("jsonrpc") == "2.0" for m in msgs)
    assert "ready" in stderr
    ping = response(msgs, 1)["result"]
    assert ping["version"] and ping["python"] and isinstance(ping["mps"], bool)
    caps = response(msgs, 2)["result"]
    assert isinstance(caps["music_generation"], bool) and isinstance(caps["beat_this"], bool)
    gen = response(msgs, 3)
    if caps["music_generation"]:
        assert gen["error"]["code"] == INVALID_PARAMS
        assert "duration_s" in gen["error"]["message"]
    else:
        assert gen["error"]["code"] == FEATURE_NOT_INSTALLED
        assert "uv sync --extra music" in gen["error"]["message"]


def test_subprocess_shutdown_cancels_and_exits():
    proc = subprocess.Popen([sys.executable, "-m", "clipper_worker"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=True)
    proc.stdin.write(request(1, "ping") + "\n" + request(2, "shutdown") + "\n")
    proc.stdin.flush()
    assert proc.wait(timeout=30) == 0
    msgs = [json.loads(line) for line in proc.stdout.read().splitlines()]
    # The ping was in flight when shutdown arrived: it either finished or was cancelled, but it was answered.
    ping = response(msgs, 1)
    assert ping.get("result", {}).get("version") or ping["error"]["code"] == REQUEST_CANCELLED
    assert response(msgs, 2)["result"] is None
