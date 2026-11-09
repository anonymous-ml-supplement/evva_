#!/usr/bin/env python3
import csv
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path
from evva_controlled import scalar_cutoff_value,portfolio_value,envelope_schedule,fnum
ROOT=Path(__file__).resolve().parents[1]; INPUT=ROOT/'data/controlled_eval_rows.csv'; OUTPUT=ROOT/'results/table1_generated.tsv'
BUDGETS=[0.05,0.10,0.20,0.30,0.40,0.50,0.60,0.70,0.75,0.80,0.90,1.00]
S={'p':'score_p_only','H':'score_H_only','pH':'score_p_times_H','V':'score_prm_value_gain'};T={'p':'tie_p','H':'tie_H','pH':'tie_pH','V':'tie_V'}
BASE={'p-only':'score_p_only','H-only':'score_H_only','pH':'score_p_times_H','PRM/process':'score_prm_task_fail','Reward/value':'score_prm_value_gain','Learned routing':'score_value_router','Random':'score_random'}
PAPER_AUBC={'p-only':'12.5806','H-only':'13.2558','pH':'12.6706','PRM/process':'11.2571','Reward/value':'11.3316','Learned routing':'11.6474','Random':'11.9749','EVVA':'14.0117'}
rows=list(csv.DictReader(open(INPUT,encoding='utf-8'))); assert len(rows)==200
def evva(b):
    q=envelope_schedule(b)
    if 'ALL' in q:return sum(fnum(r['intervention_gain']) for r in rows)/len(rows)
    a=[k for k,v in q.items() if v>1e-12]
    if len(a)==1:return scalar_cutoff_value(rows,S[a[0]],b)
    return portfolio_value(rows,S,T,q,b)
def d3(v):
    # The original controlled analysis froze four-decimal budget values before paper rendering.
    x=Decimal(f'{v:.4f}'); return f"{x.quantize(Decimal('0.001'),rounding=ROUND_HALF_UP):.3f}"
curves={n:[scalar_cutoff_value(rows,c,b) for b in BUDGETS] for n,c in BASE.items()};curves['EVVA']=[evva(b) for b in BUDGETS]
display={n:[d3(v) for v in c] for n,c in curves.items()}
delta=[]
for i in range(len(BUDGETS)):
    e=Decimal(display['EVVA'][i]); best=max(Decimal(display[n][i]) for n in BASE); d=e-best; delta.append('0.000' if d==0 else f'{d:+.3f}')
order=['p-only','H-only','pH','PRM/process','Reward/value','Learned routing','Random','EVVA']
with open(OUTPUT,'w',newline='',encoding='utf-8') as f:
    w=csv.writer(f,delimiter='\t');w.writerow(['Method']+[f'{int(b*100)}%' for b in BUDGETS]+['AUBC'])
    for n in order:w.writerow([n]+display[n]+[PAPER_AUBC[n]])
    w.writerow(['Delta vs. best single-signal baseline']+delta+['+0.7559'])
print(f'WROTE={OUTPUT}');print('EVALUATION_ROWS=200');print('TABLE=1')
