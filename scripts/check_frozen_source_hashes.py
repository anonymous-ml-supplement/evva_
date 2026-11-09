#!/usr/bin/env python3
from pathlib import Path
import hashlib
r=Path(__file__).resolve().parents[1]
expected={
'frozen_openclaw/source/aaai_evva3_final_evva_sag.py':'3a04b828762cd311e1ec27c1ffdb1f655172d5783503454bf042aa30ab0c042a',
'frozen_openclaw/source/code/aaai_v5m_signal_availability_gated_evva.py':'924b6c893036f20ee9d60e90faf34c3beeb0f830af8e6d1c8ffd4dfee904906e'}
for rel,want in expected.items():
    got=hashlib.sha256((r/rel).read_bytes()).hexdigest()
    assert got==want,(rel,got,want)
    print(rel,'SHA256=PASS')
