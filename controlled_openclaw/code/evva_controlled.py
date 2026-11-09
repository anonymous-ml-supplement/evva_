#!/usr/bin/env python3
import math
LABEL='intervention_gain'
def fnum(x,default=0.0):
    try:
        y=float(str(x).strip()); return y if math.isfinite(y) else default
    except Exception:return default
def exact_B(n,frac): return max(1,min(int(round(frac*n)),n))
def scalar_cutoff_value(rows,score_col,frac):
    B=exact_B(len(rows),frac); vals=[(fnum(r[score_col]),fnum(r[LABEL])) for r in rows]; vals.sort(key=lambda x:x[0],reverse=True)
    cutoff=vals[B-1][0]; above=[y for s,y in vals if s>cutoff]; tied=[y for s,y in vals if s==cutoff]; need=B-len(above)
    return (sum(above)+(need/len(tied))*sum(tied))/B if tied else sum(above)/B
def deterministic_rank(rows,score_col,tie_col):
    x=[(fnum(r[score_col]),int(r[tie_col]),i) for i,r in enumerate(rows)]; x.sort(key=lambda z:(z[0],z[1]),reverse=True); return [i for _,_,i in x]
def portfolio_value(rows,score_cols,tie_cols,quota,frac):
    B=exact_B(len(rows),frac); active=[(k,v) for k,v in quota.items() if v>1e-12]; selected=[];seen=set();remaining=B;targets=[]
    for k,q in active[:-1]:
        c=max(0,min(int(round(q*B)),remaining));targets.append((k,c));remaining-=c
    targets.append((active[-1][0],remaining))
    for k,target in targets:
        count=0
        for idx in deterministic_rank(rows,score_cols[k],tie_cols[k]):
            if idx in seen:continue
            seen.add(idx);selected.append(idx);count+=1
            if count>=target:break
    for fill in ['pH','V','H','p']:
        if len(selected)>=B:break
        for idx in deterministic_rank(rows,score_cols[fill],tie_cols[fill]):
            if idx in seen:continue
            seen.add(idx);selected.append(idx)
            if len(selected)>=B:break
    return sum(fnum(rows[i][LABEL]) for i in selected[:B])/B
def envelope_schedule(frac):
    return {0.05:{'H':1.0},0.10:{'H':1.0},0.20:{'pH':1.0},0.30:{'pH':1.0},0.40:{'pH':1.0},0.50:{'H':0.2,'V':0.8},0.60:{'V':1.0},0.70:{'V':1.0},0.75:{'pH':0.1,'H':0.1,'V':0.8},0.80:{'pH':0.2,'V':0.8},0.90:{'pH':0.8,'V':0.2},1.00:{'ALL':1.0}}[frac]
