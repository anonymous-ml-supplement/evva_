#!/usr/bin/env python3
import argparse
import json

from sandbox_env import apply_action


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--episode", required=True)
    parser.add_argument(
        "--action",
        required=True,
        choices=["inspect_files", "safe_edit", "risky_patch", "restore_backup", "submit"],
    )
    parser.add_argument("--branch", default="main")
    args = parser.parse_args()

    result = apply_action(
        episode_id=args.episode,
        action=args.action,
        branch=args.branch,
    )
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
