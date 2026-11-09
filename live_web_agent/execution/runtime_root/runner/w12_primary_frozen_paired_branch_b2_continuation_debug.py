from __future__ import annotations

import copy
import hashlib
import json
import math
import pickle
import sys
import time
import traceback
from pathlib import Path
from typing import Any

import bgym

from agentlab.agents.generic_agent import AGENT_GPT5_MINI

import w12_measurement_contract_v1 as contract
import w12_source_aligned_evva_hook_v1 as hook


MAX_POST_CANDIDATE_ACTIONS = 32
MAX_BRANCH_WALL_SECONDS = 1200


def select_task(task_name: str):
    benchmark = bgym.DEFAULT_BENCHMARKS["webarena_verified"]()

    matches = [
        env_args
        for env_args in benchmark.env_args_list
        if str(env_args.task_name) == task_name
    ]

    if len(matches) != 1:
        raise RuntimeError(
            "TARGET_TASK_RESOLUTION_COUNT:" + str(len(matches))
        )

    subset = benchmark.subset_from_list(
        [task_name],
        benchmark_name_suffix="_w12_source_aligned_paired_branch",
    )

    if len(subset.env_args_list) != 1:
        raise RuntimeError("SUBSET_TASK_COUNT_INVALID")

    return subset, subset.env_args_list[0]


def normalize_error(value: Any) -> str:
    if value in (None, "", False):
        return ""
    return str(value).strip()


def validation_signature(value):
    if not isinstance(value, dict):
        return {}

    node = value.get("node")
    node = node if isinstance(node, dict) else {}

    return {
        "valid": value.get("valid"),
        "action_type": value.get("action_type"),
        "bid": str(value.get("bid", "")),
        "value": value.get("value"),
        "node": {
            "bid": str(node.get("bid", "")),
            "role": str(node.get("role", "")),
            "name": str(node.get("name", "")),
            "value": str(node.get("value", "")),
        },
    }


def finite_number(value: Any) -> float | None:
    try:
        out = float(value)
    except (TypeError, ValueError):
        return None
    return out if math.isfinite(out) else None


def main() -> int:
    if len(sys.argv) != 8:
        raise RuntimeError(
            "USAGE: task_name expected_seed arm candidate_json candidate_state_pickle binding_json output_json"
        )

    task_name = sys.argv[1]
    expected_seed = int(sys.argv[2])
    arm = sys.argv[3]
    candidate_json = Path(sys.argv[4])
    state_pickle = Path(sys.argv[5])
    binding_json = Path(sys.argv[6])
    output_json = Path(sys.argv[7])

    if arm not in {"no_verify", "always_verify"}:
        raise RuntimeError("INVALID_ARM:" + arm)

    candidate = json.load(
        open(candidate_json, encoding="utf-8")
    )

    state_bytes = state_pickle.read_bytes()
    state_sha = hashlib.sha256(state_bytes).hexdigest()

    result = {
        "protocol": "W12_2C_FROZEN_PAIRED_BRANCH_V1",
        "task_name": task_name,
        "expected_seed": expected_seed,
        "arm": arm,
        "fresh_backend": True,
        "candidate_step_index": 0,
        "candidate_capture_status": candidate.get("status"),
        "candidate_state_pickle_sha256": state_sha,
        "base_action": candidate.get("base_action"),
        "verifier_called": False,
        "verified_action": None,
        "executed_candidate_action": None,
        "candidate_actions_differ": None,
        "candidate_last_action_error": "",
        "continuation_action_errors": [],
        "continuation_action_count": 0,
        "native_terminal_task_info": None,
        "native_terminal_reward": None,
        "cumulative_browsergym_reward": 0.0,
        "technical_failure": False,
        "policy_execution_failure": False,
        "failure_stage": None,
        "failure_reason": None,
        "p_h_ph_scored": False,
        "gain_computed": False,
    }

    env = None
    started = time.monotonic()

    technical_pass = True
    matched_prestate = False
    candidate_grounded = False
    candidate_executed = False
    terminated = False
    truncated = False
    native_branch_reward = None
    stop_class = contract.STOP_IN_PROGRESS

    try:
        candidate_contract_ok = (
            candidate.get("status") == "PASS_EXACT_CANDIDATE_PAIR_FROZEN"
            or
            candidate.get("protocol")
            == "W13_C3_CANDIDATE_PAIR_MATERIALIZATION_FROM_FROZEN_BINDING"
        )

        if not candidate_contract_ok:
            raise RuntimeError("EXACT_CANDIDATE_PAIR_CAPTURE_NOT_PASS")

        execution_binding = json.loads(binding_json.read_text())

        candidate["pre_state_semantic_digest"] = (
            execution_binding.get("pre_state_semantic_digest")
            or execution_binding.get("expected_pre_state_semantic_digest")
            or candidate.get("pre_state_semantic_digest")
        )

        if state_sha != execution_binding.get("candidate_state_pickle_sha256"):
            raise RuntimeError("EXECUTION_BINDING_STATE_SHA_MISMATCH")

        subset, env_args = select_task(task_name)

        actual_seed = int(env_args.task_seed or 0)
        result["actual_seed"] = actual_seed

        if actual_seed != expected_seed:
            raise RuntimeError(
                f"TASK_SEED_MISMATCH:{actual_seed}:{expected_seed}"
            )

        # External WebArena services are already provisioned.
        # Skip benchmark-wide backend preparation in B1 runtime.

        agent_args = copy.deepcopy(AGENT_GPT5_MINI)
        agent_args.set_benchmark(subset, demo_mode=False)
        agent = agent_args.make_agent()

        exp_dir = output_json.parent / (
            "env_" + arm
        )
        exp_dir.mkdir(parents=True, exist_ok=True)


        original_make_env = env_args.make_env

        def patched_make_env(*args, **kwargs):
            env = original_make_env(*args, **kwargs)
            env.pre_observation_delay = 2.0
            return env

        env_args.make_env = patched_make_env

        env = env_args.make_env(
            action_mapping=agent.action_set.to_python_code,
            exp_dir=exp_dir,
            use_raw_page_output=getattr(
                agent_args,
                "use_raw_page_output",
                False,
            ),
        )

        raw_obs, reset_info = env.reset(seed=actual_seed)

        branch_digest = hook.semantic_state_digest(raw_obs)

        result["pre_state_semantic_digest"] = branch_digest
        result["candidate_pre_state_semantic_digest"] = candidate.get(
            "pre_state_semantic_digest"
        )

        matched_prestate = (
            branch_digest
            == candidate.get("pre_state_semantic_digest")
        )

        result["MATCHED_PRESTATE"] = matched_prestate

        if not matched_prestate:
            result["failure_stage"] = "PRESTATE_MATCH"
            result["failure_reason"] = "SEMANTIC_PRESTATE_DIGEST_MISMATCH"
            stop_class = contract.STOP_IN_PROGRESS

        if matched_prestate:
            base_action = str(candidate["base_action"])
            frozen_verified_action = str(candidate["verified_action"])
            candidate_action = (
                base_action
                if arm == "no_verify"
                else frozen_verified_action
            )

            expected_sig = (
                candidate.get("base_validation_signature")
                if arm == "no_verify"
                else candidate.get("verified_validation_signature")
            )

            grounding = hook.source_action_grounding(
                agent=agent,
                raw_obs=raw_obs,
                action=candidate_action,
            )
            result["source_grounding"] = grounding

            nodes = contract.structured_nodes(raw_obs)
            branch_validation = contract.validate_action(
                action=candidate_action,
                nodes=nodes,
            )
            branch_sig = validation_signature(branch_validation)

            if expected_sig is None:
                expected_sig = branch_sig

            result["branch_action_validation"] = branch_validation
            result["branch_action_validation_signature"] = branch_sig
            result["capture_action_validation_signature"] = expected_sig
            result["action_grounding_signature_match"] = (
                branch_sig == expected_sig
            )

            candidate_grounded = bool(
                grounding.get("grounded")
                and branch_validation.get("valid") is True
                and branch_sig == expected_sig
            )

            result["verifier"] = candidate.get("verifier_result")
            result["verified_action"] = frozen_verified_action
            result["candidate_actions_differ"] = (
                frozen_verified_action != base_action
            )
            result["frozen_candidate_action_for_arm"] = candidate_action

            if not candidate_grounded:
                result["failure_stage"] = "CANDIDATE_GROUNDING"
                result["failure_reason"] = (
                    "FROZEN_BRANCH_ACTION_NOT_IDENTICALLY_GROUNDED_IN_BRANCH_PRESTATE"
                )
                stop_class = contract.STOP_IN_PROGRESS

        if matched_prestate and candidate_grounded:
            if technical_pass:
                try:
                    print(
                        "DEBUG_BEFORE_ENV_STEP",
                        {
                            "candidate_action": candidate_action,
                            "expected_bid": expected_sig.get("bid"),
                        },
                        flush=True,
                    )

                    post_obs, reward, terminated, truncated, info = env.step(
                        candidate_action
                    )

                    print(
                        "DEBUG_AFTER_ENV_STEP",
                        {
                            "candidate_action": candidate_action,
                            "reward": reward,
                            "terminated": terminated,
                            "truncated": truncated,
                            "info_last_action_error": (
                                info.get("last_action_error")
                                if isinstance(info, dict)
                                else None
                            ),
                            "obs_last_action_error": (
                                post_obs.get("last_action_error")
                                if isinstance(post_obs, dict)
                                else None
                            ),
                        },
                        flush=True,
                    )
                except Exception as exc:
                    result["failure_stage"] = "CANDIDATE_ENV_STEP"
                    result["failure_reason"] = (
                        type(exc).__name__ + ":" + str(exc)
                    )
                    result["technical_failure"] = True
                    technical_pass = False
                    stop_class = contract.STOP_TECHNICAL_FAILURE
                else:
                    result["executed_candidate_action"] = candidate_action
                    result["candidate_reward"] = finite_number(reward)
                    result["cumulative_browsergym_reward"] += float(
                        reward or 0.0
                    )
                    result["candidate_task_info"] = (
                        info.get("task_info")
                        if isinstance(info, dict)
                        else None
                    )

                    candidate_error = normalize_error(
                        info.get("last_action_error")
                        if isinstance(info, dict)
                        else ""
                    )

                    result[
                        "candidate_last_action_error"
                    ] = candidate_error

                    if candidate_error:
                        candidate_executed = False
                        result["policy_execution_failure"] = True
                        result["failure_stage"] = "CANDIDATE_ACTION_EXECUTION"
                        result["failure_reason"] = (
                            "BROWSERGYM_CANDIDATE_LAST_ACTION_ERROR:"
                            + candidate_error
                        )
                        stop_class = contract.STOP_POLICY_EXECUTION_FAILURE
                    else:
                        candidate_executed = True

                    if candidate_executed:
                        native_branch_reward = (
                            finite_number(reward)
                            if (terminated or truncated)
                            else None
                        )

                        if terminated:
                            stop_class = contract.STOP_ENV_TERMINATED
                        elif truncated:
                            stop_class = contract.STOP_ENV_TRUNCATED

                        if not (terminated or truncated):
                            state = pickle.loads(state_bytes)

                            branch_preprocessed_prestate = (
                                agent.obs_preprocessor(
                                    raw_obs.copy()
                                )
                            )

                            hook.restore_continuation_agent_state(
                                agent=agent,
                                candidate_snapshot=state,
                                branch_preprocessed_prestate=
                                    branch_preprocessed_prestate,
                                executed_candidate_action=
                                    candidate_action,
                            )

                            current_raw_obs = post_obs
                            current_info = info
                            current_reward = reward

                            for continuation_index in range(
                                1,
                                MAX_POST_CANDIDATE_ACTIONS + 1,
                            ):
                                if time.monotonic() - started > MAX_BRANCH_WALL_SECONDS:
                                    result["failure_stage"] = "CONTINUATION"
                                    result["failure_reason"] = (
                                        "W12_BRANCH_WALL_TIME_SAFETY_CENSOR"
                                    )
                                    stop_class = contract.STOP_W12_SAFETY_CENSOR
                                    break

                                processed_obs = agent.obs_preprocessor(
                                    current_raw_obs.copy()
                                )

                                try:
                                    action, agent_info = agent.get_action(
                                        processed_obs.copy()
                                    )
                                except Exception as exc:
                                    result["failure_stage"] = (
                                        "CONTINUATION_AGENT"
                                    )
                                    result["failure_reason"] = (
                                        type(exc).__name__
                                        + ":"
                                        + str(exc)
                                    )
                                    result["technical_failure"] = True
                                    technical_pass = False
                                    stop_class = contract.STOP_TECHNICAL_FAILURE
                                    break

                                if action is None:
                                    result["failure_stage"] = (
                                        "CONTINUATION_AGENT"
                                    )
                                    result["failure_reason"] = (
                                        "SOURCE_ALIGNED_AGENT_RETURNED_NONE"
                                    )
                                    result[
                                        "policy_execution_failure"
                                    ] = True
                                    stop_class = (
                                        contract.STOP_POLICY_EXECUTION_FAILURE
                                    )
                                    break

                                try:
                                    (
                                        next_raw_obs,
                                        next_reward,
                                        terminated,
                                        truncated,
                                        next_info,
                                    ) = env.step(str(action))

                                    print(
                                        "DEBUG_CONTINUATION_STEP_OK",
                                        {
                                            "index": continuation_index,
                                            "action": str(action),
                                            "info_error": (
                                                next_info.get("last_action_error")
                                                if isinstance(next_info, dict)
                                                else None
                                            ),
                                        },
                                        flush=True,
                                    )
                                except Exception as exc:
                                    result["failure_stage"] = (
                                        "CONTINUATION_ENV_STEP"
                                    )
                                    result["failure_reason"] = (
                                        type(exc).__name__
                                        + ":"
                                        + str(exc)
                                    )
                                    result["technical_failure"] = True
                                    technical_pass = False
                                    stop_class = contract.STOP_TECHNICAL_FAILURE
                                    break

                                result["continuation_action_count"] += 1
                                result["cumulative_browsergym_reward"] += float(
                                    next_reward or 0.0
                                )

                                action_error = normalize_error(
                                    next_raw_obs.get("last_action_error")
                                    if isinstance(next_raw_obs, dict)
                                    else ""
                                )

                                if action_error:
                                    result[
                                        "continuation_action_errors"
                                    ].append(
                                        {
                                            "continuation_index":
                                                continuation_index,
                                            "action": str(action),
                                            "last_action_error":
                                                action_error,
                                            "native_semantics":
                                                "OBSERVE_AND_CONTINUE",
                                        }
                                    )

                                current_raw_obs = next_raw_obs
                                current_info = next_info
                                current_reward = next_reward

                                if terminated:
                                    stop_class = contract.STOP_ENV_TERMINATED
                                    native_branch_reward = finite_number(
                                        next_reward
                                    )
                                    break

                                if truncated:
                                    stop_class = contract.STOP_ENV_TRUNCATED
                                    native_branch_reward = finite_number(
                                        next_reward
                                    )
                                    break

                            else:
                                result["failure_stage"] = "CONTINUATION"
                                result["failure_reason"] = (
                                    "MAX_POST_CANDIDATE_ACTIONS_REACHED_WITHOUT_NATIVE_BOUNDARY"
                                )
                                stop_class = contract.STOP_W12_SAFETY_CENSOR

                            if terminated or truncated:
                                result["native_terminal_task_info"] = (
                                    current_info.get("task_info")
                                    if isinstance(current_info, dict)
                                    else None
                                )
                                result["native_terminal_reward"] = (
                                    finite_number(current_reward)
                                )

        if terminated:
            stop_class = contract.STOP_ENV_TERMINATED
        elif truncated:
            stop_class = contract.STOP_ENV_TRUNCATED
        elif not technical_pass:
            stop_class = contract.STOP_TECHNICAL_FAILURE
        elif result.get("policy_execution_failure"):
            stop_class = contract.STOP_POLICY_EXECUTION_FAILURE

    except Exception as exc:
        technical_pass = False
        result["technical_failure"] = True

        if result.get("failure_stage") is None:
            result["failure_stage"] = "UNCLASSIFIED"

        if result.get("failure_reason") is None:
            result["failure_reason"] = (
                type(exc).__name__ + ":" + str(exc)
            )

        result["traceback"] = traceback.format_exc()
        stop_class = contract.STOP_TECHNICAL_FAILURE

    finally:
        result["elapsed_seconds"] = (
            time.monotonic() - started
        )
        result["terminated"] = bool(terminated)
        result["truncated"] = bool(truncated)
        result["STOP_CLASS"] = stop_class

        measurement = contract.finalize_branch_measurement(
            technical_pass=technical_pass,
            matched_prestate=matched_prestate,
            candidate_grounded=candidate_grounded,
            candidate_executed=candidate_executed,
            stop_class=stop_class,
            native_branch_reward=native_branch_reward,
            pre_state_semantic_digest=str(
                result.get(
                    "pre_state_semantic_digest",
                    "",
                )
            ),
        )

        result.update(measurement)

        output_json.parent.mkdir(
            parents=True,
            exist_ok=True,
        )
        output_json.write_text(
            json.dumps(
                result,
                indent=2,
                sort_keys=True,
                default=str,
            )
            + "\n",
            encoding="utf-8",
        )

        if env is not None:
            try:
                env.close()
            except Exception:
                pass

    return 0 if technical_pass else 2


if __name__ == "__main__":
    raise SystemExit(main())
