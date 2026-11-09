#!/usr/bin/env python3
"""Read-only independent 12-budget AUBC audit using supplied controlled rows.

Reuses released per-budget selection functions, NOT run_table1's results/TSV.
Reads PAPER_AUBC literals from legacy source via AST (without executing it)
solely as reference values; never uses them to calculate a curve.
"""
import argparse
import ast
import csv
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTROL = ROOT / 'controlled_openclaw'
sys.path.insert(0, str(CONTROL / 'code'))
from evva_controlled import scalar_cutoff_value, portfolio_value, envelope_schedule, fnum  # noqa: E402

BUDGETS = (0.05, 0.10, 0.20, 0.30, 0.40, 0.50, 0.60, 0.70, 0.75, 0.80, 0.90, 1.0)
BASE = {
    'p-only':'score_p_only', 'H-only':'score_H_only', 'pH':'score_p_times_H',
    'PRM/process':'score_prm_task_fail', 'Reward/value':'score_prm_value_gain',
    'Learned routing':'score_value_router', 'Random':'score_random'
}
S = {'p':'score_p_only','H':'score_H_only','pH':'score_p_times_H','V':'score_prm_value_gain'}
T = {'p':'tie_p','H':'tie_H','pH':'tie_pH','V':'tie_V'}
TOLERANCE = 0.0002  # Fourth-decimal frozen/reporting differences in legacy exports.


def printed_reference():
    source = ast.parse((CONTROL/'code/run_table1.py').read_text(encoding='utf-8'))
    for node in source.body:
        if isinstance(node, ast.Assign) and any(isinstance(t,ast.Name) and t.id == 'PAPER_AUBC' for t in node.targets):
            return ast.literal_eval(node.value)
    raise RuntimeError('Legacy PAPER_AUBC literal dictionary not found')


def calculate_evva(rows, b):
    quota = envelope_schedule(b)
    if 'ALL' in quota:
        return sum(fnum(r['intervention_gain']) for r in rows)/len(rows)
    active = [k for k, q in quota.items() if q > 1e-12]
    if len(active) == 1:
        return scalar_cutoff_value(rows, S[active[0]], b)
    return portfolio_value(rows, S, T, quota, b)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--output', type=Path, default=ROOT/'docs/CONTROLLED_AUBC_RECALC_CHECK.csv')
    args = ap.parse_args()
    with (CONTROL/'data/controlled_eval_rows.csv').open(newline='', encoding='utf-8') as f:
        rows = list(csv.DictReader(f))
    if len(rows) != 200:
        raise RuntimeError(f'Expected bundled 200-row controlled subset; got {len(rows)}')
    paper = printed_reference()
    if set(paper) != set(BASE)|{'EVVA'}:
        raise RuntimeError('Reference method set differs from independently computed method set')
    output = []
    for method in [*BASE, 'EVVA']:
        curve = ([scalar_cutoff_value(rows, BASE[method], b) for b in BUDGETS]
                 if method in BASE else [calculate_evva(rows, b) for b in BUDGETS])
        calculated = sum(curve)/len(curve)  # unrounded: do not use displayed d3 cells
        displayed = float(paper[method])
        diff = calculated - displayed
        status = 'PASS' if abs(diff) <= TOLERANCE else 'REVIEW'
        output.append({
            'method': method,
            'paper_restated_AUBC':paper[method],
            'recomputed_unrounded_AUBC':f'{calculated:.12f}',
            'signed_difference_recalc_minus_paper':f'{diff:+.12f}',
            'absolute_difference':f'{abs(diff):.12f}',
            'tolerance_absolute': f'{TOLERANCE:.7f}',
            'decision':status,
            'rows':len(rows),
            'budget_count':len(BUDGETS),
            'reconstruction':'200 bundled candidate rows + existing scalar_cutoff_value / portfolio_value / envelope_schedule',
            'paper_reference_origin':'PAPER_AUBC literal in unchanged legacy run_table1.py',
            'tolerance_note':'2e-4 covers observed <=~1.34e-4 legacy four-decimal/display/export differences; not a statistical tolerance',
        })
    args.output.parent.mkdir(parents=True,exist_ok=True)
    with args.output.open('w',newline='',encoding='utf-8') as f:
        w=csv.DictWriter(f,fieldnames=list(output[0]));w.writeheader();w.writerows(output)
    maximum = max(float(x['absolute_difference']) for x in output)
    print(f'AUBC_CHECK_ROWS={len(output)} INPUT_CANDIDATES={len(rows)} BUDGETS={len(BUDGETS)} MAX_ABS_DELTA={maximum:.12f}')
    print('AUBC_CHECK=' + ('PASS' if all(x['decision']=='PASS' for x in output) else 'REVIEW'))
    print('OUTPUT=' + str(args.output))
    if any(x['decision']=='REVIEW' for x in output):
        raise SystemExit(2)

if __name__=='__main__':
    main()
