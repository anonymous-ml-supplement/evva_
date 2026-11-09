#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path
from typing import Any, Dict

from sandbox_env import EPISODES_DIR, apply_action, load_state
from rollout_policy import run_default_rollout


BRANCH_UNVERIFIED_SUFFIX = '__branch_wrong'
BRANCH_VERIFIED_SUFFIX = '__branch_corrected'


def clone_episode(src_episode: str, dst_episode: str) -> Path:
    src = EPISODES_DIR / src_episode
    dst = EPISODES_DIR / dst_episode
    if not src.exists():
        raise FileNotFoundError(f'Source episode not found: {src_episode}')
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst)
    return dst


def cleanup_branch_clones(source_episode: str) -> None:
    for suffix in (BRANCH_UNVERIFIED_SUFFIX, BRANCH_VERIFIED_SUFFIX):
        path = EPISODES_DIR / f'{source_episode}{suffix}'
        if path.exists():
            shutil.rmtree(path)


def _branch_summary(episode_id: str, first_action_result: Dict[str, Any], rollout: Dict[str, Any]) -> Dict[str, Any]:
    final_state = load_state(episode_id)
    return {
        'episode_id': episode_id,
        'first_action_result': first_action_result,
        'rollout': rollout,
        'final_total_reward': float(final_state['total_reward']),
        'final_success': int(final_state['success']),
        'final_done': int(final_state['done']),
        'metadata_corrupted': int(final_state['metadata_corrupted']),
        'irreversible_failure': int(final_state['irreversible_failure']),
        'restore_used': int(final_state['restore_used']),
        'check_passed': int(final_state['check_passed']),
    }


def run_branch_replay(
    source_episode: str,
    candidate_action: str = 'risky_patch',
    corrected_action: str = 'safe_edit',
    cleanup: bool = False,
) -> Dict[str, Any]:
    wrong_episode = f'{source_episode}{BRANCH_UNVERIFIED_SUFFIX}'
    corrected_episode = f'{source_episode}{BRANCH_VERIFIED_SUFFIX}'

    cleanup_branch_clones(source_episode)
    clone_episode(source_episode, wrong_episode)
    clone_episode(source_episode, corrected_episode)

    wrong_first = apply_action(wrong_episode, candidate_action)
    wrong_rollout = run_default_rollout(wrong_episode)
    wrong_summary = _branch_summary(wrong_episode, wrong_first, wrong_rollout)

    corrected_first = apply_action(corrected_episode, corrected_action)
    corrected_rollout = run_default_rollout(corrected_episode)
    corrected_summary = _branch_summary(corrected_episode, corrected_first, corrected_rollout)

    source_state = load_state(source_episode)
    reward_wrong = float(wrong_summary['final_total_reward'])
    reward_corrected = float(corrected_summary['final_total_reward'])
    branch_harm_exact = reward_corrected - reward_wrong

    result = {
        'status': 'ok',
        'source_episode': source_episode,
        'candidate_action': candidate_action,
        'corrected_action': corrected_action,
        'wrong_continuation': wrong_summary,
        'corrected_continuation': corrected_summary,
        'impact_summary': {
            'impact_definition': 'reward_corrected_continuation - reward_wrong_continuation',
            'reward_wrong_continuation': reward_wrong,
            'reward_corrected_continuation': reward_corrected,
            'branch_harm_exact': branch_harm_exact,
            'reversibility': source_state.get('reversibility'),
            'coupling_strength': source_state.get('coupling_strength'),
            'case_type': source_state.get('case_type'),
        },
    }

    if cleanup:
        cleanup_branch_clones(source_episode)

    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--episode', required=True)
    parser.add_argument('--candidate-action', default='risky_patch', choices=['risky_patch', 'safe_edit'])
    parser.add_argument('--corrected-action', default='safe_edit', choices=['risky_patch', 'safe_edit'])
    parser.add_argument('--cleanup', action='store_true')
    args = parser.parse_args()

    result = run_branch_replay(
        source_episode=args.episode,
        candidate_action=args.candidate_action,
        corrected_action=args.corrected_action,
        cleanup=args.cleanup,
    )
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
