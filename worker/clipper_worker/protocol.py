"""Newline-delimited JSON-RPC 2.0 over stdio.

One JSON object per line in each direction. Requests run on a thread pool so that `$/cancel`, `ping` and other quick
calls are answered while a long generation is in flight. Every write to the protocol stream goes through one lock.

Notifications sent by the worker:
    {"jsonrpc": "2.0", "method": "progress", "params": {"id": <request id>, "fraction": 0..1, "message": "..."}}

Notifications accepted by the worker:
    {"jsonrpc": "2.0", "method": "$/cancel", "params": {"id": <request id>}}
"""

from __future__ import annotations

import json
import logging
import os
import sys
import threading
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, IO, Optional

log = logging.getLogger("clipper_worker")

# Standard JSON-RPC 2.0 codes.
PARSE_ERROR = -32700
INVALID_REQUEST = -32600
METHOD_NOT_FOUND = -32601
INVALID_PARAMS = -32602
INTERNAL_ERROR = -32603
# Application codes (JSON-RPC reserves -32000…-32099 for implementation-defined server errors).
FEATURE_NOT_INSTALLED = -32001
GENERATION_FAILED = -32002
REQUEST_CANCELLED = -32800  # same value LSP uses


class RPCError(Exception):
    """An error that is sent back to the client as a JSON-RPC error object."""

    def __init__(self, code: int, message: str, data: Any = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.data = data

    def to_json(self) -> Dict[str, Any]:
        err: Dict[str, Any] = {"code": self.code, "message": self.message}
        if self.data is not None:
            err["data"] = self.data
        return err


class Cancelled(RPCError):
    def __init__(self) -> None:
        super().__init__(REQUEST_CANCELLED, "Request cancelled")


@dataclass
class RequestContext:
    """Passed to handlers: progress reporting and cooperative cancellation for one request."""

    id: Any
    _server: "Server"
    _cancelled: threading.Event = field(default_factory=threading.Event)

    @property
    def cancelled(self) -> bool:
        return self._cancelled.is_set()

    def check_cancelled(self) -> None:
        if self._cancelled.is_set():
            raise Cancelled()

    def progress(self, fraction: float, message: Optional[str] = None) -> None:
        params: Dict[str, Any] = {"id": self.id, "fraction": max(0.0, min(1.0, float(fraction)))}
        if message:
            params["message"] = message
        self._server.notify("progress", params)


Handler = Callable[[Dict[str, Any], RequestContext], Any]


class Server:
    def __init__(self, handlers: Dict[str, Handler], out: IO[str], max_workers: int = 4):
        self.handlers = handlers
        self._out = out
        self._write_lock = threading.Lock()
        self._pool = ThreadPoolExecutor(max_workers=max_workers, thread_name_prefix="rpc")
        self._active: Dict[Any, RequestContext] = {}
        self._active_lock = threading.Lock()
        self._shutdown = threading.Event()

    # MARK: output

    def _write(self, message: Dict[str, Any]) -> None:
        line = json.dumps(message, separators=(",", ":"), ensure_ascii=False, allow_nan=False)
        with self._write_lock:
            try:
                self._out.write(line + "\n")
                self._out.flush()
            except (BrokenPipeError, ValueError):
                # The client went away; the read loop will see EOF and exit.
                self._shutdown.set()

    def notify(self, method: str, params: Any) -> None:
        self._write({"jsonrpc": "2.0", "method": method, "params": params})

    def _respond(self, id: Any, result: Any) -> None:
        self._write({"jsonrpc": "2.0", "id": id, "result": result})

    def _error(self, id: Any, error: RPCError) -> None:
        self._write({"jsonrpc": "2.0", "id": id, "error": error.to_json()})

    # MARK: input

    def handle_line(self, line: str) -> None:
        line = line.strip()
        if not line:
            return
        try:
            message = json.loads(line)
        except json.JSONDecodeError as exc:
            self._error(None, RPCError(PARSE_ERROR, f"Parse error: {exc}"))
            return
        if not isinstance(message, dict) or message.get("jsonrpc") != "2.0" or not isinstance(message.get("method"), str):
            self._error(message.get("id") if isinstance(message, dict) else None,
                        RPCError(INVALID_REQUEST, "Invalid request: expected a JSON-RPC 2.0 object with a method"))
            return

        method: str = message["method"]
        params = message.get("params", {})
        has_id = "id" in message
        id = message.get("id")

        if method == "$/cancel":
            target = params.get("id") if isinstance(params, dict) else None
            with self._active_lock:
                ctx = self._active.get(target)
            if ctx is not None:
                log.info("cancel requested for %r", target)
                ctx._cancelled.set()
            return
        if method in ("shutdown", "exit"):
            if has_id:
                self._respond(id, None)
            self._shutdown.set()
            return
        if not has_id:
            log.warning("ignoring unknown notification %s", method)
            return

        handler = self.handlers.get(method)
        if handler is None:
            self._error(id, RPCError(METHOD_NOT_FOUND, f"Method not found: {method}",
                                     {"available": sorted(self.handlers)}))
            return
        if params is None:
            params = {}
        if not isinstance(params, dict):
            self._error(id, RPCError(INVALID_PARAMS, "params must be an object"))
            return

        ctx = RequestContext(id=id, _server=self)
        with self._active_lock:
            self._active[id] = ctx
        self._pool.submit(self._run, handler, params, ctx)

    def _run(self, handler: Handler, params: Dict[str, Any], ctx: RequestContext) -> None:
        try:
            ctx.check_cancelled()
            result = handler(params, ctx)
            if ctx.cancelled:
                raise Cancelled()
            self._respond(ctx.id, result)
        except RPCError as err:
            self._error(ctx.id, err)
        except Exception as exc:  # noqa: BLE001 - every failure must become an error object
            log.exception("request %r failed", ctx.id)
            self._error(ctx.id, RPCError(INTERNAL_ERROR, f"{type(exc).__name__}: {exc}"))
        finally:
            with self._active_lock:
                self._active.pop(ctx.id, None)

    def serve(self, stdin: IO[str]) -> None:
        """Read requests until EOF or `shutdown`.

        On EOF, requests already received still run to completion and get their responses (so `printf ... | worker`
        works). An explicit `shutdown` cancels them instead.
        """
        for line in stdin:
            self.handle_line(line)
            if self._shutdown.is_set():
                with self._active_lock:
                    for ctx in self._active.values():
                        ctx._cancelled.set()
                break
        self._pool.shutdown(wait=True, cancel_futures=False)


def claim_stdout() -> IO[str]:
    """Reserve the real stdout for the protocol and point fd 1 (and `sys.stdout`) at stderr.

    Libraries print freely (ACE-Step's downloader uses `print`, C extensions write to fd 1). Anything that isn't a
    protocol message must never reach the client's stdout pipe, so the protocol gets a private duplicate of fd 1 and
    fd 1 itself becomes stderr.
    """
    sys.stdout.flush()
    protocol_fd = os.dup(1)
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    return os.fdopen(protocol_fd, "w", encoding="utf-8", buffering=1)


def watch_parent(interval: float = 1.0) -> None:
    """Exit when the parent dies (e.g. `uv run` was SIGKILLed and we got reparented to launchd)."""
    parent = os.getppid()

    def _loop() -> None:
        while True:
            threading.Event().wait(interval)
            if os.getppid() != parent:
                log.warning("parent process %d went away; exiting", parent)
                os._exit(0)

    threading.Thread(target=_loop, name="parent-watch", daemon=True).start()
