from __future__ import annotations

import ast
import math
from dataclasses import dataclass
from typing import Any, Iterable

SCHEMA_VERSION = "W12_MEASUREMENT_CONTRACT_V1"
CHANGED_ACTION_REPLICATES_PER_ARM = 3
NOMINAL_BUDGET_GRID = (0.05, 0.10, 0.20, 0.30, 0.40, 0.50, 0.60, 0.70, 0.75, 0.80, 0.90, 1.00)
AUBC_BUDGET_GRID = tuple(q for q in NOMINAL_BUDGET_GRID if q < 1.0)
TEXT_INPUT_ROLES = frozenset({"textbox", "searchbox", "combobox"})
GLOBAL_ACTIONS = frozenset({"scroll(0, 500)", "scroll(0, -500)", "press('HOME')", "press('END')"})

STOP_ENV_TERMINATED = "ENVIRONMENT_TERMINATED"
STOP_ENV_TRUNCATED = "ENVIRONMENT_TRUNCATED"
STOP_TECHNICAL_FAILURE = "TECHNICAL_FAILURE"
STOP_POLICY_EXECUTION_FAILURE = "POLICY_EXECUTION_FAILURE"
STOP_W12_SAFETY_CENSOR = "W12_SAFETY_TIME_HORIZON_CENSOR"
STOP_IN_PROGRESS = "IN_PROGRESS"
ACCEPTABLE_OUTCOME_STOPS = frozenset({STOP_ENV_TERMINATED, STOP_ENV_TRUNCATED})


def canonical_exact_B(n: int, frac: float) -> int:
    if n < 1:
        raise ValueError("N_MUST_BE_POSITIVE")
    if not math.isfinite(float(frac)) or float(frac) <= 0.0 or float(frac) > 1.0:
        raise ValueError("BUDGET_FRACTION_OUT_OF_RANGE")
    return max(1, min(int(round(float(frac) * n)), n))


def _scalar(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, (str, int, float, bool)):
        return str(value)
    if isinstance(value, dict):
        for key in ("value", "text", "name", "string"):
            if key in value:
                out = _scalar(value[key])
                if out:
                    return out
    if isinstance(value, (list, tuple)):
        for child in value:
            out = _scalar(child)
            if out:
                return out
    return ""


def _first(node: dict[str, Any], names: Iterable[str]) -> str:
    for name in names:
        if name not in node:
            continue
        value = _scalar(node.get(name)).strip()
        if value:
            return value
    return ""


def structured_nodes(observation: dict[str, Any]) -> list[dict[str, Any]]:
    tree = observation.get("axtree_object")
    if not isinstance(tree, dict):
        return []
    raw_nodes = tree.get("nodes")
    if not isinstance(raw_nodes, list):
        return []
    output = []
    for index, node in enumerate(raw_nodes):
        if not isinstance(node, dict):
            continue
        bid = _first(node, ("browsergym_id", "bid"))
        if not bid:
            continue
        ignored = _scalar(node.get("ignored")).lower() == "true"
        disabled = _scalar(node.get("disabled")).lower() == "true"
        if ignored or disabled:
            continue
        output.append({
            "node_index": index,
            "bid": bid,
            "role": _first(node, ("role", "role_name")).lower(),
            "name": _first(node, ("name", "accessible_name", "label", "text")),
            "value": _first(node, ("value", "current_value")),
        })
    return output


def node_capabilities(node: dict[str, Any]) -> tuple[str, ...]:
    capabilities = ["click"]
    if str(node.get("role", "")).lower() in TEXT_INPUT_ROLES:
        capabilities.append("fill")
    return tuple(capabilities)


def action_surface(nodes: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    surface: dict[str, dict[str, Any]] = {}
    for node in nodes:
        bid = str(node.get("bid", "")).strip()
        if not bid:
            continue
        surface[bid] = {
            "bid": bid,
            "role": str(node.get("role", "")).lower(),
            "name": str(node.get("name", "")),
            "value": str(node.get("value", "")),
            "allowed_verbs": node_capabilities(node),
        }
    return surface


def compact_action_surface(nodes: list[dict[str, Any]], limit: int = 180) -> str:
    surface = action_surface(nodes)
    rows = []
    for item in list(surface.values())[:limit]:
        verbs = ",".join(item["allowed_verbs"])
        rows.append(
            "- "
            + f"BID={item['bid']} | allowed={verbs} | role={item['role']} | "
            + f"name={item['name'][:240]!r} | value={item['value'][:240]!r}"
        )
    return "\n".join(rows)


def parse_action(action: str) -> tuple[str, tuple[Any, ...]]:
    try:
        expr = ast.parse(str(action).strip(), mode="eval").body
    except SyntaxError as exc:
        raise ValueError("ACTION_SYNTAX_INVALID") from exc
    if not isinstance(expr, ast.Call) or not isinstance(expr.func, ast.Name) or expr.keywords:
        raise ValueError("ACTION_CALL_INVALID")
    name = expr.func.id
    try:
        args = tuple(ast.literal_eval(arg) for arg in expr.args)
    except (ValueError, TypeError) as exc:
        raise ValueError("ACTION_ARGUMENT_NOT_LITERAL") from exc
    return name, args


def validate_action(*, action: str, nodes: list[dict[str, Any]]) -> dict[str, Any]:
    try:
        name, args = parse_action(action)
    except ValueError as exc:
        return {"valid": False, "reason": str(exc), "action": str(action)}

    surface = action_surface(nodes)

    if name == "click" and len(args) == 1 and isinstance(args[0], str):
        bid = args[0]
        item = surface.get(bid)
        if item is None:
            return {"valid": False, "reason": "CLICK_BID_NOT_IN_ACTION_SURFACE", "bid": bid}
        if "click" not in item["allowed_verbs"]:
            return {"valid": False, "reason": "CLICK_NOT_ALLOWED_BY_ACTION_SURFACE", "bid": bid}
        return {"valid": True, "action_type": "click", "bid": bid, "node": item}

    if name == "fill" and len(args) == 2 and all(isinstance(x, str) for x in args):
        bid, value = args
        item = surface.get(bid)
        if item is None:
            return {"valid": False, "reason": "FILL_BID_NOT_IN_ACTION_SURFACE", "bid": bid}
        if "fill" not in item["allowed_verbs"]:
            return {"valid": False, "reason": "FILL_NOT_ALLOWED_BY_ACTION_SURFACE", "bid": bid, "role": item["role"]}
        return {"valid": True, "action_type": "fill", "bid": bid, "value": value, "node": item}

    if name == "scroll" and args in ((0, 500), (0, -500)):
        return {"valid": True, "action_type": "scroll"}

    if name == "press" and len(args) == 1 and args[0] in ("HOME", "END"):
        return {"valid": True, "action_type": "press"}

    if name == "send_msg_to_user" and len(args) == 1 and isinstance(args[0], str):
        return {"valid": True, "action_type": "send_msg_to_user"}

    return {"valid": False, "reason": "ACTION_OUTSIDE_FROZEN_W12_CONTRACT", "action": str(action)}


def proposal_contract_text(nodes: list[dict[str, Any]]) -> str:
    return (
        "The action surface below is authoritative. Propose only actions allowed by the listed BID capabilities.\n"
        + compact_action_surface(nodes)
        + "\nGlobal allowed actions: scroll(0, 500), scroll(0, -500), press('HOME'), press('END'), send_msg_to_user('<brief final answer>')."
    )


def classify_stop(*, terminated: bool, truncated: bool, technical_failure: bool = False, policy_execution_failure: bool = False, safety_censor: bool = False) -> str:
    if terminated:
        return STOP_ENV_TERMINATED
    if truncated:
        return STOP_ENV_TRUNCATED
    if technical_failure:
        return STOP_TECHNICAL_FAILURE
    if policy_execution_failure:
        return STOP_POLICY_EXECUTION_FAILURE
    if safety_censor:
        return STOP_W12_SAFETY_CENSOR
    return STOP_IN_PROGRESS


def _finite_number(value: Any) -> bool:
    try:
        return math.isfinite(float(value))
    except (TypeError, ValueError):
        return False


def finalize_branch_measurement(*, technical_pass: bool, matched_prestate: bool, candidate_grounded: bool, candidate_executed: bool, stop_class: str, native_branch_reward: Any, pre_state_semantic_digest: str) -> dict[str, Any]:
    outcome_observed = stop_class in ACCEPTABLE_OUTCOME_STOPS
    no_artificial_abort = outcome_observed
    reward_valid = _finite_number(native_branch_reward)
    accepted = all((
        technical_pass,
        matched_prestate,
        candidate_grounded,
        candidate_executed,
        no_artificial_abort,
        outcome_observed,
        reward_valid,
        bool(str(pre_state_semantic_digest).strip()),
    ))
    return {
        "schema_version": SCHEMA_VERSION,
        "TECHNICAL_PASS": bool(technical_pass),
        "MATCHED_PRESTATE": bool(matched_prestate),
        "CANDIDATE_GROUNDED": bool(candidate_grounded),
        "CANDIDATE_EXECUTED": bool(candidate_executed),
        "NO_ARTIFICIAL_CONTINUATION_ABORT": bool(no_artificial_abort),
        "ENVIRONMENT_OUTCOME_BOUNDARY_OBSERVED": bool(outcome_observed),
        "MEASUREMENT_ACCEPTED": bool(accepted),
        "STOP_CLASS": str(stop_class),
        "NATIVE_BRANCH_REWARD": float(native_branch_reward) if reward_valid else None,
        "PRE_STATE_SEMANTIC_DIGEST": str(pre_state_semantic_digest),
    }


def require_changed_action_measurements(*, no_verify_branches: list[dict[str, Any]], always_verify_branches: list[dict[str, Any]]) -> dict[str, Any]:
    required = CHANGED_ACTION_REPLICATES_PER_ARM
    errors = []
    if len(no_verify_branches) != required:
        errors.append(f"NO_VERIFY_REPLICATE_COUNT:{len(no_verify_branches)}")
    if len(always_verify_branches) != required:
        errors.append(f"ALWAYS_VERIFY_REPLICATE_COUNT:{len(always_verify_branches)}")
    all_branches = list(no_verify_branches) + list(always_verify_branches)
    for index, branch in enumerate(all_branches, start=1):
        if branch.get("MEASUREMENT_ACCEPTED") is not True:
            errors.append(f"BRANCH_{index}_MEASUREMENT_NOT_ACCEPTED")
    digests = {str(branch.get("PRE_STATE_SEMANTIC_DIGEST", "")) for branch in all_branches}
    if "" in digests or len(digests) != 1:
        errors.append("MATCHED_PRESTATE_DIGEST_SET_INVALID")
    return {"accepted": not errors, "errors": errors, "required_replicates_per_arm": required}


def estimate_candidate_gain_guarded(*, base_action: str, verified_action: str, no_verify_branches: list[dict[str, Any]], always_verify_branches: list[dict[str, Any]], frozen_gain_module: Any) -> dict[str, Any]:
    same_action = str(base_action) == str(verified_action)
    if same_action:
        result = frozen_gain_module.estimate_candidate_gain(
            base_action=str(base_action),
            verified_action=str(verified_action),
            no_verify_returns=[],
            always_verify_returns=[],
        )
        return {
            "GAIN_ACCEPTED": True,
            "GAIN_STATUS": "STRUCTURAL_ZERO_SAME_ACTION",
            "GAIN_CENSORED_OR_MISSING": False,
            **result,
        }

    gate = require_changed_action_measurements(
        no_verify_branches=no_verify_branches,
        always_verify_branches=always_verify_branches,
    )
    if not gate["accepted"]:
        return {
            "GAIN_ACCEPTED": False,
            "GAIN_STATUS": "CHANGED_ACTION_MEASUREMENT_CENSORED_OR_MISSING",
            "GAIN_CENSORED_OR_MISSING": True,
            "intervention_gain": None,
            "acceptance_errors": gate["errors"],
        }

    nv = [float(branch["NATIVE_BRANCH_REWARD"]) for branch in no_verify_branches]
    av = [float(branch["NATIVE_BRANCH_REWARD"]) for branch in always_verify_branches]
    result = frozen_gain_module.estimate_candidate_gain(
        base_action=str(base_action),
        verified_action=str(verified_action),
        no_verify_returns=nv,
        always_verify_returns=av,
    )
    return {
        "GAIN_ACCEPTED": True,
        "GAIN_STATUS": "CHANGED_ACTION_COMPLETE_MATCHED_MEASUREMENT",
        "GAIN_CENSORED_OR_MISSING": False,
        **result,
    }
