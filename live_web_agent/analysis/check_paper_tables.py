#!/usr/bin/env python3
from pathlib import Path
import csv, subprocess, sys
ROOT=Path(__file__).resolve().parents[1]
subprocess.run([sys.executable,str(ROOT/'analysis'/'run_paper_tables.py')],cwd=ROOT,check=True)
def rows(name):
    return list(csv.DictReader(open(ROOT/'results'/name,encoding='utf-8'),delimiter='\t'))
t2=rows('Table2_Live_Exact_Budget.tsv')
by={r['Method']:r for r in t2}
assert by['Random']['AUBC']=='0.472436'
assert by['pH']['AUBC']=='0.698718'
assert by['EVVA']['AUBC']=='0.756410'
assert by['EVVA']['5%']=='0.1538' and by['EVVA']['10%']=='0.1538'
s4=rows('TableS4_Execution_Level_Robustness.tsv')
a=[r for r in s4 if r['Budget']=='AUBC'][0]
assert a['Random']=='0.5200' and a['pH']=='0.6963' and a['EVVA']=='0.7803' and a['Oracle']=='0.9515'
s6=rows('TableS6_Bootstrap_CI.tsv'); b={r['Baseline']:r for r in s6}
assert b['pH']['Boot. mean']=='0.047116' and b['pH']['P_boot(Delta > 0)']=='0.7925'
assert b['H']['Boot. mean']=='0.059325' and b['H']['P_boot(Delta > 0)']=='0.8706'
assert b['p']['Boot. mean']=='0.196200' and b['p']['P_boot(Delta > 0)']=='0.9932'
s8=rows('TableS8_Switch_Ablation.tsv'); x={r['Analysis']:r for r in s8}
assert x['Switch permutation']['AUBC']=='0.742064' and x['EVVA - Switch mean']['AUBC']=='+0.014346'
print('PAPER_TABLE_CHECK=PASS')
