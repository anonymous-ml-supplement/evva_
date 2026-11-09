from __future__ import annotations

import copy
import hashlib
import json
import re
from collections import Counter
from typing import Any
from urllib.parse import urlsplit

import w12_measurement_contract_v1 as contract


BID_ACTIONS = {
    "click",
    "dblclick",
    "hover",
    "fill",
    "select_option",
    "check",
    "uncheck",
    "focus",
}

BID_PATTERN = re.compile(
    r"^\s*([A-Za-z_][A-Za-z0-9_]*)\(\s*(['\"])([^'\"]+)\2"
)


def normalize_text(value: Any) -> str:
    return re.sub(r"\s+", " ", "" if value is None else str(value)).strip()


def goal_text(raw_obs: dict[str, Any]) -> str:
    goal = raw_obs.get("goal")
    if isinstance(goal, str) and goal.strip():
        return goal.strip()

    parts = []
    for item in raw_obs.get("goal_object") or []:
        if isinstance(item, dict) and item.get("type") == "text":
            parts.append(str(item.get("text", "")))

    return "\n".join(parts).strip()


def semantic_state_digest(raw_obs: dict[str, Any]) -> str:
    url = str(raw_obs.get("url", ""))
    parsed = urlsplit(url)

    signatures = Counter()

    for node in contract.structured_nodes(raw_obs):
        signatures[
            "|".join([
                "role=" + normalize_text(node.get("role", "")).lower(),
                "name=" + normalize_text(node.get("name", "")),
                "value=" + normalize_text(node.get("value", "")),
            ])
        ] += 1

    payload = {
        "route": {
            "path": parsed.path,
            "query": parsed.query,
            "fragment": parsed.fragment,
        },
        "goal_sha256":
            hashlib.sha256(goal_text(raw_obs).encode("utf-8")).hexdigest(),
        "node_multiset": sorted(signatures.items()),
    }

    return hashlib.sha256(
        json.dumps(
            payload,
            sort_keys=True,
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()


def source_action_grounding(
    *,
    agent: Any,
    raw_obs: dict[str, Any],
    action: str,
) -> dict[str, Any]:
    report = {
        "action": str(action),
        "mapping_parse_pass": False,
        "referenced_bid": None,
        "referenced_bid_present": None,
        "grounded": False,
        "error": None,
    }

    try:
        agent.action_set.to_python_code(str(action))
        report["mapping_parse_pass"] = True
    except Exception as exc:
        report["error"] = type(exc).__name__ + ":" + str(exc)
        return report

    match = BID_PATTERN.match(str(action))

    if match and match.group(1) in BID_ACTIONS:
        bid = match.group(3)
        report["referenced_bid"] = bid

        bids = {
            str(node.get("bid"))
            for node in contract.structured_nodes(raw_obs)
            if node.get("bid") not in (None, "")
        }

        present = bid in bids
        report["referenced_bid_present"] = present
        report["grounded"] = bool(present)
    else:
        report["referenced_bid_present"] = None
        report["grounded"] = True

    return report


def snapshot_agent_after_candidate(agent: Any) -> dict[str, Any]:
    return {
        "plan": copy.deepcopy(agent.plan),
        "plan_step": copy.deepcopy(agent.plan_step),
        "memories": copy.deepcopy(agent.memories),
        "thoughts": copy.deepcopy(agent.thoughts),
        "actions": copy.deepcopy(agent.actions),
    }


def capture_first_live_candidate(
    *,
    agent: Any,
    raw_obs: dict[str, Any],
) -> dict[str, Any]:
    processed_obs = agent.obs_preprocessor(raw_obs.copy())

    action, agent_info = agent.get_action(processed_obs.copy())

    if action is None:
        raise RuntimeError("SOURCE_AGENT_RETURNED_NONE_AT_CANDIDATE_STEP")

    grounding = source_action_grounding(
        agent=agent,
        raw_obs=raw_obs,
        action=str(action),
    )

    return {
        "candidate_step_index": 0,
        "base_action": str(action),
        "pre_state_semantic_digest": semantic_state_digest(raw_obs),
        "grounding": grounding,
        "agent_state_after_candidate": snapshot_agent_after_candidate(agent),
        "agent_think": getattr(agent_info, "think", None),
    }


def restore_continuation_agent_state(
    *,
    agent: Any,
    candidate_snapshot: dict[str, Any],
    branch_preprocessed_prestate: dict[str, Any],
    executed_candidate_action: str,
) -> None:
    agent.plan = copy.deepcopy(candidate_snapshot["plan"])
    agent.plan_step = copy.deepcopy(candidate_snapshot["plan_step"])
    agent.memories = copy.deepcopy(candidate_snapshot["memories"])
    agent.thoughts = copy.deepcopy(candidate_snapshot["thoughts"])
    agent.actions = copy.deepcopy(candidate_snapshot["actions"])

    if not agent.actions:
        raise RuntimeError("CANDIDATE_AGENT_ACTION_HISTORY_EMPTY")

    agent.actions[-1] = str(executed_candidate_action)
    agent.obs_history = [copy.deepcopy(branch_preprocessed_prestate)]


def matched_prestate(
    *,
    frozen_digest: str,
    branch_raw_obs: dict[str, Any],
) -> bool:
    return (
        bool(str(frozen_digest).strip())
        and semantic_state_digest(branch_raw_obs) == str(frozen_digest)
    )
