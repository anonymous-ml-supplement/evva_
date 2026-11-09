#!/usr/bin/env python3
"""Read-only local path crosswalk for 180 supplied runtime bindings.

Never imports browser code, executes a workload, loads a pickle, or rewrites a binding.
"""
import argparse
import csv
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT/'live_web_agent/execution/runtime_root'
BINDINGS = RUNTIME/'source_stream/04k_stream/runtime_bindings'
CONSTRUCTOR = RUNTIME/'constructor'
CANDIDATE_PATTERN = re.compile(r'^W13PRIMARY\d+$')


def rel(path):
    return path.relative_to(ROOT).as_posix()


def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda:f.read(1024*1024),b''):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--output',type=Path,default=ROOT/'docs/WEB_RUNTIME_BINDING_PATH_CHECK.csv')
    args=ap.parse_args()
    files=sorted(BINDINGS.glob('*.runtime_binding.json'))
    output=[]
    for binding_path in files:
        binding=json.loads(binding_path.read_text(encoding='utf-8'))
        cid=binding['candidate_id']
        if not CANDIDATE_PATTERN.fullmatch(cid):
            raise ValueError('Unexpected candidate identifier')
        pair_relative=binding['candidate_pair']
        pickle_relative=binding['candidate_state_pickle']
        pair=(binding_path.parent / pair_relative).resolve()
        # Deliberately record this *incorrect* common-base interpretation as a diagnostic only.
        pickle_from_json=(binding_path.parent/pickle_relative).resolve()
        # The relative pickle string resolves from the 04k_stream directory, not runtime_bindings/.
        pickle_from_stream=(BINDINGS.parent/pickle_relative).resolve()
        # The original runner uses CONSTRUCTOR / 'candidates' / cid / 'candidate_state.pkl'.
        state=(CONSTRUCTOR/'candidates'/cid/'candidate_state.pkl').resolve()
        if not pair.is_relative_to(RUNTIME.resolve()) or not state.is_relative_to(RUNTIME.resolve()):
            raise ValueError('Path resolves outside supplied runtime_root')
        pair_found=pair.is_file()
        state_found=state.is_file()
        pair_sha='PASS' if pair_found and sha(pair)==binding.get('candidate_pair_sha256') else 'MISMATCH_OR_MISSING'
        state_sha='PASS' if state_found and sha(state)==binding.get('candidate_state_pickle_sha256') else 'MISMATCH_OR_MISSING'
        output.append({
            'binding_file':rel(binding_path),
            'candidate_id':cid,
            'arm':binding.get('arm',''),
            'replicate':binding.get('replicate',''),
            'candidate_pair_relative_in_json':pair_relative,
            'candidate_pair_base':'runtime_binding JSON parent',
            'candidate_pair_located_at':rel(pair),
            'candidate_pair_found':'YES' if pair_found else 'NO',
            'candidate_pair_sha256_match':pair_sha,
            'candidate_state_pickle_relative_in_json':pickle_relative,
            'pickle_relative_to_json_parent_exists':'YES' if pickle_from_json.is_file() else 'NO',
            'pickle_relative_to_04k_stream_exists':'YES' if pickle_from_stream.is_file() else 'NO',
            'pickle_relative_to_04k_stream_equals_runner_path':'YES' if pickle_from_stream==state else 'NO',
            'candidate_state_pickle_actual_base':'runtime_root/constructor/candidates/<candidate_id>/candidate_state.pkl (runner root)',
            'candidate_state_pickle_located_at':rel(state),
            'candidate_state_pickle_found':'YES' if state_found else 'NO',
            'candidate_state_pickle_sha256_match':state_sha,
            'path_crosswalk_status':'PASS' if pair_found and state_found and pair_sha=='PASS' and state_sha=='PASS' and pickle_from_stream==state else 'REVIEW',
            'replay_status':'NOT RUN',
        })
    args.output.parent.mkdir(parents=True,exist_ok=True)
    if not output:
        raise RuntimeError('No runtime bindings located')
    with args.output.open('w',newline='',encoding='utf-8') as f:
        w=csv.DictWriter(f,fieldnames=list(output[0]));w.writeheader();w.writerows(output)
    print(f'BINDINGS={len(output)} PAIRS_LOCATED={sum(x["candidate_pair_found"]=="YES" for x in output)} '
          f'STATES_LOCATED={sum(x["candidate_state_pickle_found"]=="YES" for x in output)} '
          f'JSON_PARENT_STATE_PATHS_LOCATED={sum(x["pickle_relative_to_json_parent_exists"]=="YES" for x in output)}')
    print('WEB_BINDING_CROSSWALK=' + ('PASS' if len(output)==180 and all(x['path_crosswalk_status']=='PASS' for x in output) else 'REVIEW'))
    print('WEB_REPLAY=NOT RUN')
    print('OUTPUT=' + str(args.output))
    if len(output)!=180 or any(x['path_crosswalk_status']!='PASS' for x in output):
        raise SystemExit(2)

if __name__=='__main__':
    main()
