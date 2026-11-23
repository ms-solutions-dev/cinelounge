"""Start the CL server branch locally on macOS.

The only change against production: `resource.setrlimit` raises ValueError on
macOS for RLIMIT_AS ("current limit exceeds maximum limit"), which kills every
forked portal call. The limits protect against runaway portal scripts and have nothing
to do with roles, so here a failing setrlimit is ignored.

    CL_DATA=/path python launch_server.py <port>
"""

import resource
import sys

_orig = resource.setrlimit


def _tolerant(which, limits):
    try:
        _orig(which, limits)
    except (ValueError, OSError):
        pass


resource.setrlimit = _tolerant

import uvicorn  # noqa: E402

uvicorn.run("cinelounge.web.main:app", host="127.0.0.1", port=int(sys.argv[1]), log_level="warning")
