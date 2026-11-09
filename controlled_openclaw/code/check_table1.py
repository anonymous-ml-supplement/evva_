#!/usr/bin/env python3
from pathlib import Path
import subprocess,sys
ROOT=Path(__file__).resolve().parents[1]
subprocess.run([sys.executable,str(ROOT/'code/run_table1.py')],cwd=ROOT,check=True)
a=(ROOT/'results/table1_generated.tsv').read_text();b=(ROOT/'results/table1_reference.tsv').read_text()
if a!=b:
    print('CHECK=FAIL');
    import difflib;print(''.join(difflib.unified_diff(b.splitlines(True),a.splitlines(True),fromfile='reference',tofile='generated')));raise SystemExit(1)
print('CHECK=PASS');print('TABLE=1');print('EVALUATION_ROWS=200');print('ROWS=9')
