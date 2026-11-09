#!/usr/bin/env python3
"""Release-local integrity for the two key EVVA evaluator files (after public naming)."""
from pathlib import Path
import hashlib
root=Path(__file__).resolve().parents[1]
expected={'frozen_openclaw/source/evva3_final_evva_sag.py': 'fdecabbc52cdbdcd4086a6f891930bdd161b66675d6e665443309477c751856a', 'frozen_openclaw/source/code/evva_v5m_signal_availability_gated_evva.py': '924366a39ac2081c82f28850f22c0b94cd146f65ccdf0e288157fcbc0d8a1f4c'}
for rel, want in expected.items():
    path=root/rel
    got=hashlib.sha256(path.read_bytes()).hexdigest()
    assert got==want,(rel,got,want)
    print(rel,'SHA256=PASS (current anonymous release)')
