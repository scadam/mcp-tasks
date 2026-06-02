"""Shared pytest configuration.

Forces fast tool delays for the local in-process suite so tests don't wait the
production 20s/300s. The deployment smoke test (``test_deployment.py``) does not
import this behavior — it runs against whatever the deployed app is configured
with.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

# Make the src-layout package importable without an editable install.
_SRC = Path(__file__).resolve().parent.parent / "src"
if str(_SRC) not in sys.path:
    sys.path.insert(0, str(_SRC))

# Fast delays for local tests (overridable by the environment).
os.environ.setdefault("BIKES_TOOL_1_DELAY_SECONDS", "0")
os.environ.setdefault("BIKES_TOOL_2_DELAY_SECONDS", "1")
