#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
RUNS_DIR = BASE_DIR / 'runs'


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--episode', required=True)
    parser.add_argument('--case', required=True, choices=['easy', 'dependency_sensitive', 'corruption_prone'])
    parser.add_argument('--seed', type=int, required=True)
    parser.add_argument('--model', default='openai/gpt-5.4-mini')
    parser.add_argument('--mode-plan', default='agent_decides')
    parser.add_argument('--impact-threshold', type=float, default=3.0)
    parser.add_argument('--prompt-file', default='')
    args = parser.parse_args()

    ts = datetime.now(timezone.utc).strftime('%Y%m%d_%H%M%S')
    run_id = f'{ts}_{args.episode}_{args.case}_seed{args.seed}'
    run_dir = RUNS_DIR / run_id
    run_dir.mkdir(parents=True, exist_ok=False)

    prompt_text = ''
    if args.prompt_file:
        prompt_path = Path(args.prompt_file).expanduser().resolve()
        prompt_text = prompt_path.read_text(encoding='utf-8')

    manifest = {
        'run_id': run_id,
        'created_at_utc': datetime.now(timezone.utc).isoformat(),
        'episode_id': args.episode,
        'case_type': args.case,
        'seed': args.seed,
        'model': args.model,
        'mode_plan': args.mode_plan,
        'impact_threshold': args.impact_threshold,
        'base_dir': str(BASE_DIR),
        'run_dir': str(run_dir),
    }

    (run_dir / 'manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    (run_dir / 'prompt.txt').write_text(prompt_text, encoding='utf-8')
    (run_dir / 'notes.txt').write_text('', encoding='utf-8')

    print(json.dumps({
        'status': 'ok',
        'run_id': run_id,
        'run_dir': str(run_dir),
        'files_created': ['manifest.json', 'prompt.txt', 'notes.txt'],
    }, indent=2))


if __name__ == '__main__':
    main()
