#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, Dict


def load_json(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding='utf-8'))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--run-dir', required=True)
    parser.add_argument('--reset-json', required=True)
    parser.add_argument('--final-json', required=True)
    args = parser.parse_args()

    run_dir = Path(args.run_dir).expanduser().resolve()
    reset_path = Path(args.reset_json).expanduser().resolve()
    final_path = Path(args.final_json).expanduser().resolve()

    reset_data = load_json(reset_path)
    final_data = load_json(final_path)

    (run_dir / 'reset_output.json').write_text(json.dumps(reset_data, indent=2), encoding='utf-8')
    (run_dir / 'final_output.json').write_text(json.dumps(final_data, indent=2), encoding='utf-8')

    summary = {
        'episode_id': final_data.get('episode_id'),
        'case_type': final_data.get('case_type') or reset_data.get('case_type'),
        'reversibility': final_data.get('reversibility') or reset_data.get('reversibility'),
        'coupling_strength': final_data.get('coupling_strength') or reset_data.get('coupling_strength'),
        'public_risk_label': reset_data.get('public_risk_label'),
        'public_risk_hint': reset_data.get('public_risk_hint'),
        'mode': final_data.get('mode'),
        'requested_action': final_data.get('requested_action'),
        'final_action': final_data.get('final_action'),
        'corrected': final_data.get('corrected'),
        'verification_cost': final_data.get('verification_cost'),
        'harm_threshold': final_data.get('harm_threshold'),
        'branch_harm_exact': final_data.get('branch_harm_exact'),
        'reward_wrong_continuation': final_data.get('reward_wrong_continuation'),
        'reward_corrected_continuation': final_data.get('reward_corrected_continuation'),
        'success': final_data.get('success'),
        'done': final_data.get('done'),
        'irreversible_failure': final_data.get('irreversible_failure'),
        'metadata_corrupted': final_data.get('metadata_corrupted'),
        'total_reward': final_data.get('total_reward'),
    }

    (run_dir / 'summary.json').write_text(json.dumps(summary, indent=2), encoding='utf-8')

    print(json.dumps({
        'status': 'ok',
        'run_dir': str(run_dir),
        'files_created': ['reset_output.json', 'final_output.json', 'summary.json'],
        'summary': summary,
    }, indent=2))


if __name__ == '__main__':
    main()
