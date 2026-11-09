import csv
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

ROOT = Path(os.environ["ROOT"])
STREAM = Path(os.environ["STREAM_04K"])
CONSTRUCTOR = Path(os.environ["CONSTRUCTOR"])
GUARDED_RUNNER = Path(os.environ["GUARDED_RUNNER"])
IMAGE = os.environ["IMAGE"]
REDDIT_IMAGE = os.environ["REDDIT_IMAGE"]
ENV_FILE = Path(os.environ["ENV_FILE"])
OVERRIDE = Path(os.environ["OVERRIDE"])
RUN_DIR = Path(os.environ["RUN_DIR"])
OUT = Path(os.environ["OUT"])

PAIR_DIR = STREAM / "candidate_pairs"
BINDING_DIR = STREAM / "runtime_bindings"

CID_RE = re.compile(r"^(W13PRIMARY\d+)_(always_verify|no_verify)_rep(\d+)\.candidate_pair\.json$")

def sha256(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for b in iter(lambda: f.read(1024 * 1024), b""):
            h.update(b)
    return h.hexdigest()

def read_text(p: Path) -> str:
    if not p.exists():
        return "<<MISSING>>"
    return p.read_text(encoding="utf-8", errors="replace")

def read_json(p: Path):
    try:
        return json.loads(read_text(p))
    except Exception as e:
        return {"_json_error": f"{type(e).__name__}: {e}", "_raw": read_text(p)[:6000]}

def write_json(p: Path, obj) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(obj, indent=2, sort_keys=True), encoding="utf-8")

def cid_num(cid: str) -> int:
    m = re.search(r"(\d+)$", cid)
    return int(m.group(1)) if m else 10**9

def walk_values(obj):
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield k, v
            yield from walk_values(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from walk_values(v)

def first_string_key(obj, keys):
    keys = set(keys)
    if isinstance(obj, dict):
        for k in keys:
            v = obj.get(k)
            if isinstance(v, str) and v:
                return v
    for k, v in walk_values(obj):
        if k in keys and isinstance(v, str) and v:
            return v
    return None

def first_int_key(obj, keys):
    keys = set(keys)
    if isinstance(obj, dict):
        for k in keys:
            v = obj.get(k)
            if isinstance(v, int):
                return v
            if isinstance(v, str) and v.isdigit():
                return int(v)
    for k, v in walk_values(obj):
        if k in keys:
            if isinstance(v, int):
                return v
            if isinstance(v, str) and v.isdigit():
                return int(v)
    return None

def docker(cmd, stdout_path=None, stderr_to_stdout=True, check=False):
    if stdout_path is None:
        return subprocess.run(
            cmd,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT if stderr_to_stdout else subprocess.PIPE,
            check=check,
        )

    with stdout_path.open("a", encoding="utf-8", errors="replace") as f:
        p = subprocess.Popen(
            cmd,
            text=True,
            stdout=f,
            stderr=subprocess.STDOUT if stderr_to_stdout else subprocess.PIPE,
        )
        start = time.time()
        last = time.time()
        while True:
            rc = p.poll()
            now = time.time()
            if rc is not None:
                if check and rc != 0:
                    raise subprocess.CalledProcessError(rc, cmd)
                class Result:
                    pass
                r = Result()
                r.returncode = rc
                return r

            if now - last >= 60:
                print(
                    "HEARTBEAT=BRANCH_SUBPROCESS_STILL_RUNNING "
                    f"TOTAL_WAIT_SEC={int(now - start)} "
                    f"CMD_HEAD={' '.join(str(x) for x in cmd[:8])}",
                    flush=True,
                )
                last = now

            time.sleep(5)

def cleanup(network, backend):
    subprocess.run(["docker", "rm", "-f", backend], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["docker", "network", "rm", network], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def backend_ready(network, log_path):
    for _ in range(30):
        r = docker([
            "docker", "run", "--rm",
            "--network", network,
            IMAGE,
            "python", "-c",
            "import urllib.request; urllib.request.urlopen('http://reddit', timeout=2); print('READY')",
        ], stdout_path=log_path)
        if r.returncode == 0:
            return True
        time.sleep(2)
    return False

def build_schedule():
    rows = []
    for pair in sorted(PAIR_DIR.glob("W13PRIMARY*_*.candidate_pair.json")):
        m = CID_RE.match(pair.name)
        if not m:
            raise RuntimeError(f"BAD_PAIR_FILENAME:{pair.name}")

        cid, arm, rep_s = m.group(1), m.group(2), m.group(3)
        rep = int(rep_s)

        binding = BINDING_DIR / pair.name.replace(".candidate_pair.json", ".runtime_binding.json")
        state = CONSTRUCTOR / "candidates" / cid / "candidate_state.pkl"

        if not binding.exists():
            raise RuntimeError(f"BINDING_MISSING:{binding}")
        if not state.exists():
            raise RuntimeError(f"STATE_MISSING:{state}")

        pair_obj = read_json(pair)
        binding_obj = read_json(binding)

        task_name = (
            first_string_key(binding_obj, ["task_name", "webarena_task_name", "task"])
            or first_string_key(pair_obj, ["task_name", "webarena_task_name", "task"])
        )
        seed = (
            first_int_key(binding_obj, ["seed", "expected_seed", "task_seed"])
            or first_int_key(pair_obj, ["seed", "expected_seed", "task_seed"])
        )

        # Seed/task fallback from frozen constructor candidate JSON.
        # This is still pre-outcome metadata only; no runtime, no reward, no gain.
        constructor_jsons = sorted((CONSTRUCTOR / "candidates" / cid).rglob("*.json"))

        if not task_name:
            task_hits = []
            for jp in constructor_jsons:
                jobj = read_json(jp)
                t = first_string_key(jobj, ["task_name", "webarena_task_name", "task"])
                if t:
                    task_hits.append((str(jp), t))
            unique_tasks = sorted({x[1] for x in task_hits})
            if len(unique_tasks) == 1:
                task_name = unique_tasks[0]
            else:
                raise RuntimeError(f"TASK_NAME_UNRESOLVED:{pair.name}:TASK_HITS={task_hits}")

        if seed is None:
            seed_hits = []
            seed_keys = [
                "seed", "expected_seed", "task_seed",
                "candidate_seed", "webarena_seed", "env_seed",
                "actual_seed", "source_seed",
            ]
            for jp in constructor_jsons:
                jobj = read_json(jp)
                s = first_int_key(jobj, seed_keys)
                if s is not None:
                    seed_hits.append((str(jp), s))
            unique_seeds = sorted({x[1] for x in seed_hits})
            if len(unique_seeds) == 1:
                seed = unique_seeds[0]
            else:
                raise RuntimeError(f"SEED_UNRESOLVED:{pair.name}:SEED_HITS={seed_hits}")

        rows.append({
            "candidate_id": cid,
            "arm": arm,
            "replicate": rep,
            "task_name": task_name,
            "seed": seed,
            "pair": pair,
            "binding": binding,
            "state": state,
            "branch": f"{cid}_{arm}_rep{rep}",
        })

    rows = sorted(rows, key=lambda r: (cid_num(r["candidate_id"]), r["arm"], r["replicate"]))

    if len(rows) != 180:
        raise RuntimeError(f"SCHEDULED_BRANCH_COUNT_NOT_180:{len(rows)}")

    cids = sorted({r["candidate_id"] for r in rows}, key=cid_num)
    if len(cids) != 30:
        raise RuntimeError(f"CANDIDATE_COUNT_NOT_30:{len(cids)}")

    return rows

def accepted_output(obj):
    return (
        obj.get("TECHNICAL_PASS") is True
        and obj.get("MEASUREMENT_ACCEPTED") is True
        and obj.get("MATCHED_PRESTATE") is True
        and obj.get("CANDIDATE_EXECUTED") is True
        and obj.get("CANDIDATE_GROUNDED") is True
        and obj.get("ENVIRONMENT_OUTCOME_BOUNDARY_OBSERVED") is True
    )

def main():
    started = datetime.now().isoformat()

    required = [STREAM, CONSTRUCTOR, GUARDED_RUNNER, ENV_FILE, OVERRIDE, PAIR_DIR, BINDING_DIR]
    missing = [str(p) for p in required if not p.exists()]
    if missing:
        raise RuntimeError("REQUIRED_PATHS_MISSING:" + json.dumps(missing))

    rows = build_schedule()

    schedule_tsv = OUT / "01_tables" / "step5b_04k_full180_schedule.tsv"
    with schedule_tsv.open("w", encoding="utf-8", newline="") as f:
        cols = ["branch_index", "candidate_id", "arm", "replicate", "task_name", "seed", "pair", "binding", "state"]
        w = csv.DictWriter(f, fieldnames=cols, delimiter="\t")
        w.writeheader()
        for i, r in enumerate(rows, 1):
            rr = dict(r)
            rr["branch_index"] = i
            rr["pair"] = str(rr["pair"])
            rr["binding"] = str(rr["binding"])
            rr["state"] = str(rr["state"])
            w.writerow({c: rr.get(c) for c in cols})

    run_manifest = {
        "CURRENT": "W13_STEP5B_FORMAL_PAIRED_EXECUTION_04K_FULL180",
        "timestamp": started,
        "RUN_DIR": str(RUN_DIR),
        "OUT": str(OUT),
        "STREAM_04K": str(STREAM),
        "CONSTRUCTOR": str(CONSTRUCTOR),
        "GUARDED_RUNNER": str(GUARDED_RUNNER),
        "GUARDED_RUNNER_SHA256": sha256(GUARDED_RUNNER),
        "IMAGE": IMAGE,
        "REDDIT_IMAGE": REDDIT_IMAGE,
        "ENV_FILE_PATH_ONLY": str(ENV_FILE),
        "OVERRIDE": str(OVERRIDE),
        "OVERRIDE_SHA256": sha256(OVERRIDE),
        "SCHEDULE_TSV": str(schedule_tsv),
        "SCHEDULED_BRANCH_COUNT": len(rows),
        "FORMAL_EXECUTION_START": True,
        "RUNTIME_CONTEXT": "DOCKER_KNOWN_GOOD_B2_HANDOFF",
        "SCOPE": "STEP5B_ONLY_NO_GAIN_NO_D_NO_TABLE2_NO_HELDOUT",
        "REPLAY_CANARY_AS_FORMAL": False,
        "PATCH_APPLIED_TO_ORIGINAL": False,
        "GAIN_COMPUTED_FOR_PRIMARY": False,
        "D_EVALUATE_RUN": False,
        "TABLE2_GENERATED": False,
        "HELDOUT_TOUCHED": False,
        "DO_NOT_TOUCH": "STEP1_STEP2_STEP3_STEP4,FROZEN_CANDIDATES,FROZEN_PREOUTCOME_SCORE_LEDGER,GAIN,D,TABLE2,HELDOUT",
    }
    write_json(OUT / "03_reports" / "step5b_04k_full180_start_manifest.json", run_manifest)

    branch_records = []
    fail_close = None

    print("CURRENT=W13_STEP5B_FORMAL_PAIRED_EXECUTION_04K_FULL180")
    print(f"RUN_DIR={RUN_DIR}")
    print(f"OUT={OUT}")
    print(f"SCHEDULED_BRANCH_COUNT={len(rows)}")
    print("FORMAL_EXECUTION_START=YES")
    print("REPLAY_CANARY_AS_FORMAL=False")
    print("SCOPE=STEP5B_ONLY_NO_GAIN_NO_D_NO_TABLE2_NO_HELDOUT")

    for idx, r in enumerate(rows, 1):
        branch = r["branch"]
        cid = r["candidate_id"]
        arm = r["arm"]
        rep = r["replicate"]
        task_name = r["task_name"]
        seed = r["seed"]

        output_json = RUN_DIR / "runner_outputs" / f"{branch}.runner_output.json"
        stdout_log = RUN_DIR / "stdout_stderr" / f"{branch}.stdout_stderr.log"
        backend_log = RUN_DIR / "stdout_stderr" / f"{branch}.backend.log"
        slot_manifest = RUN_DIR / "slot_manifests" / f"{branch}.slot_manifest.json"

        network = f"w13-04k-full180-{cid.lower()}-{arm.replace('_','')}-r{rep}-{int(time.time())}"
        backend = f"{network}-reddit"

        t0 = time.time()
        ready = False
        rc = 999

        cleanup(network, backend)
        try:
            backend_log.write_text(
                "\n".join([
                    "CURRENT=W13_STEP5B_04K_FULL180_BACKEND_START",
                    f"BRANCH={branch}",
                    f"NETWORK={network}",
                    f"BACKEND={backend}",
                    f"TASK_NAME={task_name}",
                    f"SEED={seed}",
                    "",
                ]),
                encoding="utf-8",
            )

            docker(["docker", "network", "create", network], stdout_path=backend_log)

            docker([
                "docker", "run", "-d",
                "--name", backend,
                "--network", network,
                "--network-alias", "reddit",
                REDDIT_IMAGE,
            ], stdout_path=backend_log)

            ready = backend_ready(network, backend_log)
            with backend_log.open("a", encoding="utf-8") as f:
                f.write(f"\nBACKEND_READY={ready}\n")
            if not ready:
                raise RuntimeError("BACKEND_NOT_READY")

            time.sleep(10)

            cmd = [
                "docker", "run", "--rm",
                "--network", network,
                "--env-file", str(ENV_FILE),
                "-e", "WA_REDDIT=http://reddit",
                "-e", "WA_SHOPPING=http://127.0.0.1:7770",
                "-e", "WA_SHOPPING_ADMIN=http://127.0.0.1:7780/admin",
                "-e", "WA_HOMEPAGE=http://127.0.0.1:7770",
                "-e", "WA_GITLAB=http://127.0.0.1:8023",
                "-e", "WA_MAP=http://127.0.0.1:3000",
                "-e", "WA_WIKIPEDIA=http://127.0.0.1:8888",
                "-v", f"{ROOT}:{ROOT}",
                "-v", f"{OVERRIDE}:/usr/local/lib/python3.12/site-packages/agentlab/agents/generic_agent/agent_configs.py",
                "-w", f"{ROOT}/02_runtime_vendor/core",
                "-e", f"PYTHONPATH={ROOT}/02_runtime_vendor/core:{ROOT}",
                IMAGE,
                "python", str(GUARDED_RUNNER),
                task_name,
                str(seed),
                arm,
                str(r["pair"]),
                str(r["state"]),
                str(r["binding"]),
                str(output_json),
            ]

            rc = docker(cmd, stdout_path=stdout_log).returncode

        except Exception as e:
            with stdout_log.open("a", encoding="utf-8", errors="replace") as f:
                f.write("\nLAUNCHER_EXCEPTION=" + repr(e) + "\n")
            rc = 998

        finally:
            cleanup(network, backend)

        elapsed = round(time.time() - t0, 2)
        obj = read_json(output_json) if output_json.exists() else {}
        accepted = rc == 0 and output_json.exists() and accepted_output(obj)

        record = {
            "branch_index": idx,
            "candidate_id": cid,
            "arm": arm,
            "replicate": rep,
            "branch": branch,
            "task_name": task_name,
            "seed": seed,
            "returncode": rc,
            "accepted": accepted,
            "backend_ready": ready,
            "elapsed_seconds": elapsed,
            "runner_output_exists": output_json.exists(),
            "TECHNICAL_PASS": obj.get("TECHNICAL_PASS"),
            "MEASUREMENT_ACCEPTED": obj.get("MEASUREMENT_ACCEPTED"),
            "MATCHED_PRESTATE": obj.get("MATCHED_PRESTATE"),
            "CANDIDATE_EXECUTED": obj.get("CANDIDATE_EXECUTED"),
            "CANDIDATE_GROUNDED": obj.get("CANDIDATE_GROUNDED"),
            "ENVIRONMENT_OUTCOME_BOUNDARY_OBSERVED": obj.get("ENVIRONMENT_OUTCOME_BOUNDARY_OBSERVED"),
            "STOP_CLASS": obj.get("STOP_CLASS"),
            "failure_stage": obj.get("failure_stage"),
            "failure_reason": obj.get("failure_reason"),
            "native_terminal_reward": obj.get("native_terminal_reward"),
            "NATIVE_BRANCH_REWARD": obj.get("NATIVE_BRANCH_REWARD"),
            "gain_computed": obj.get("gain_computed"),
            "traceback_present": bool(obj.get("traceback")) if isinstance(obj, dict) else False,
            "candidate_pair": str(r["pair"]),
            "runtime_binding": str(r["binding"]),
            "candidate_state": str(r["state"]),
            "runner_output": str(output_json),
            "stdout_log": str(stdout_log),
            "backend_log": str(backend_log),
        }

        write_json(slot_manifest, {
            **record,
            "CURRENT": "W13_STEP5B_04K_FULL180_SLOT_MANIFEST",
            "PATCH_APPLIED_TO_ORIGINAL": False,
            "GAIN_COMPUTED_FOR_PRIMARY": False,
            "D_EVALUATE_RUN": False,
            "TABLE2_GENERATED": False,
            "HELDOUT_TOUCHED": False,
        })

        branch_records.append(record)

        marker_dir = RUN_DIR / ("accepted" if accepted else "failed")
        write_json(marker_dir / f"{branch}.json", record)

        print(
            f"BRANCH {idx:03d}/180 STATUS={'ACCEPTED' if accepted else 'FAILED'} "
            f"CID={cid} ARM={arm} REP={rep} RC={rc} "
            f"MEASUREMENT_ACCEPTED={obj.get('MEASUREMENT_ACCEPTED')} "
            f"MATCHED_PRESTATE={obj.get('MATCHED_PRESTATE')} "
            f"CANDIDATE_EXECUTED={obj.get('CANDIDATE_EXECUTED')} "
            f"FAILURE_REASON={obj.get('failure_reason')} "
            f"ELAPSED_SEC={elapsed}",
            flush=True,
        )

        if not accepted:
            fail_close = record
            print("FAIL_FAST=YES")
            break

    accepted_count = sum(1 for r in branch_records if r["accepted"])
    failed_count = sum(1 for r in branch_records if not r["accepted"])

    record_tsv = OUT / "01_tables" / "step5b_04k_full180_branch_records.tsv"
    with record_tsv.open("w", encoding="utf-8", newline="") as f:
        cols = [
            "branch_index", "candidate_id", "arm", "replicate", "branch",
            "task_name", "seed", "returncode", "accepted", "backend_ready",
            "elapsed_seconds", "TECHNICAL_PASS", "MEASUREMENT_ACCEPTED",
            "MATCHED_PRESTATE", "CANDIDATE_EXECUTED", "CANDIDATE_GROUNDED",
            "ENVIRONMENT_OUTCOME_BOUNDARY_OBSERVED", "STOP_CLASS",
            "failure_stage", "failure_reason", "native_terminal_reward",
            "NATIVE_BRANCH_REWARD", "gain_computed", "traceback_present",
            "candidate_pair", "runtime_binding", "candidate_state",
            "runner_output", "stdout_log", "backend_log",
        ]
        w = csv.DictWriter(f, fieldnames=cols, delimiter="\t")
        w.writeheader()
        for rr in branch_records:
            w.writerow({c: rr.get(c) for c in cols})

    candidate_summary = []
    for cid in sorted({r["candidate_id"] for r in branch_records}, key=cid_num):
        cr = [r for r in branch_records if r["candidate_id"] == cid]
        candidate_summary.append({
            "candidate_id": cid,
            "scheduled_or_attempted_branch_count": len(cr),
            "accepted_branch_count": sum(1 for r in cr if r["accepted"]),
            "failed_branch_count": sum(1 for r in cr if not r["accepted"]),
            "arms_seen": ",".join(sorted({r["arm"] for r in cr})),
        })

    candidate_tsv = OUT / "01_tables" / "step5b_04k_full180_candidate_summary.tsv"
    with candidate_tsv.open("w", encoding="utf-8", newline="") as f:
        cols = ["candidate_id", "scheduled_or_attempted_branch_count", "accepted_branch_count", "failed_branch_count", "arms_seen"]
        w = csv.DictWriter(f, fieldnames=cols, delimiter="\t")
        w.writeheader()
        for rr in candidate_summary:
            w.writerow(rr)

    full_pass = accepted_count == 180 and failed_count == 0 and fail_close is None

    report = {
        "CURRENT": "W13_STEP5B_FORMAL_PAIRED_EXECUTION_04K_FULL180",
        "timestamp_start": started,
        "timestamp_end": datetime.now().isoformat(),
        "RUN_DIR": str(RUN_DIR),
        "OUT": str(OUT),
        "STREAM_04K": str(STREAM),
        "CONSTRUCTOR": str(CONSTRUCTOR),
        "GUARDED_RUNNER": str(GUARDED_RUNNER),
        "IMAGE": IMAGE,
        "REDDIT_IMAGE": REDDIT_IMAGE,
        "scheduled_branch_count": 180,
        "attempted_branch_count": len(branch_records),
        "accepted_branch_count": accepted_count,
        "failed_branch_count": failed_count,
        "full_pass": full_pass,
        "fail_close_record": fail_close,
        "record_tsv": str(record_tsv),
        "candidate_tsv": str(candidate_tsv),
        "run_manifest_start": str(OUT / "03_reports" / "step5b_04k_full180_start_manifest.json"),
        "DECISION": "PASS_STEP5B_04K_FULL180_ALL_BRANCHES_ACCEPTED_READY_FOR_OFFLINE_STEP5C" if full_pass else "FAIL_CLOSE_STEP5B_04K_FULL180_INCOMPLETE_DO_NOT_RUN_STEP5C",
        "NEXT": "RUN_OFFLINE_STEP5C_GAIN_LEDGER_FROM_04K_FULL180_OUTPUTS" if full_pass else "READ_FIRST_FAILED_BRANCH_AND_REPAIR_BEFORE_STEP5C",
        "PATCH_APPLIED_TO_ORIGINAL": False,
        "B_FULL_RUN_PERFORMED": True,
        "ENV_STEP_OPENED": True,
        "GAIN_COMPUTED_FOR_PRIMARY": False,
        "D_EVALUATE_RUN": False,
        "TABLE2_GENERATED": False,
        "HELDOUT_TOUCHED": False,
        "DO_NOT_TOUCH": "STEP1_STEP2_STEP3_STEP4,FROZEN_CANDIDATES,FROZEN_PREOUTCOME_SCORE_LEDGER,GAIN,D,TABLE2,HELDOUT",
    }

    report_path = OUT / "03_reports" / "step5b_04k_full180_final_report.json"
    write_json(report_path, report)

    summary_lines = [
        "CURRENT=W13_STEP5B_FORMAL_PAIRED_EXECUTION_04K_FULL180",
        f"OUT={OUT}",
        f"RUN_DIR={RUN_DIR}",
        f"DECISION={report['DECISION']}",
        "REPLAY_CANARY_AS_FORMAL=False",
        f"SCHEDULED_BRANCH_COUNT=180",
        f"ATTEMPTED_BRANCH_COUNT={len(branch_records)}",
        f"ACCEPTED_BRANCH_COUNT={accepted_count}",
        f"FAILED_BRANCH_COUNT={failed_count}",
        f"FULL_PASS={full_pass}",
        f"FIRST_FAIL_BRANCH={fail_close.get('branch') if fail_close else None}",
        f"FIRST_FAIL_REASON={fail_close.get('failure_reason') if fail_close else None}",
        f"RECORD_TSV={record_tsv}",
        f"CANDIDATE_TSV={candidate_tsv}",
        f"REPORT={report_path}",
        f"NEXT={report['NEXT']}",
        "PATCH_APPLIED_TO_ORIGINAL=False",
        "B_FULL_RUN_PERFORMED=True",
        "GAIN_COMPUTED_FOR_PRIMARY=False",
        "D_EVALUATE_RUN=False",
        "TABLE2_GENERATED=False",
        "HELDOUT_TOUCHED=False",
        "DO_NOT_TOUCH=STEP1_STEP2_STEP3_STEP4,FROZEN_CANDIDATES,FROZEN_PREOUTCOME_SCORE_LEDGER,GAIN,D,TABLE2,HELDOUT",
    ]

    summary_path = OUT / "03_reports" / "step5b_04k_full180_summary.txt"
    summary_path.write_text("\n".join(summary_lines) + "\n", encoding="utf-8")
    print("\n".join(summary_lines), flush=True)

    return 0 if full_pass else 20

if __name__ == "__main__":
    raise SystemExit(main())
