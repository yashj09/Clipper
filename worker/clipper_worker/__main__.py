"""`python -m clipper_worker`: serve JSON-RPC on stdin/stdout until EOF. Logs go to stderr."""

from __future__ import annotations

import logging
import os
import sys

from .methods import HANDLERS
from .protocol import Server, claim_stdout, watch_parent


def main() -> None:
    logging.basicConfig(stream=sys.stderr, level=os.environ.get("CLIPPER_WORKER_LOG", "INFO"),
                        format="[worker] %(levelname)s %(name)s: %(message)s")
    # Hugging Face / tokenizers spawn threads and progress bars; keep them quiet and off stdout.
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
    os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
    out = claim_stdout()
    watch_parent()
    logging.getLogger("clipper_worker").info("ready (pid %d)", os.getpid())
    Server(HANDLERS, out).serve(sys.stdin)


if __name__ == "__main__":
    main()
