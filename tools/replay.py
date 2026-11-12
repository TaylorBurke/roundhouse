#!/usr/bin/python3 -I
"""Replay a recorded roundhouse log into another log, as if it were happening now.

  tools/replay.py SOURCE.jsonl TARGET_DIR [--sid 520a9593] [--speed 1] [--max-gap 1.5]

Timestamps are shifted so the first event is "now" and gaps longer than --max-gap seconds
are squeezed, so a long session plays in a short time. Run the window with
LOT_MAP_DIR=TARGET_DIR to watch it. For development and screenshots only: it writes to
TARGET_DIR/events.jsonl and touches nothing else.
"""
import argparse
import json
import os
import sys
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source")
    parser.add_argument("target_dir")
    parser.add_argument("--sid", help="only this session (first 8 characters of its id)")
    parser.add_argument("--speed", type=float, default=1.0)
    parser.add_argument("--max-gap", type=float, default=1.5)
    args = parser.parse_args()

    events = []
    with open(args.source, encoding="utf-8") as f:
        for line in f:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if args.sid and e.get("sid") != args.sid:
                continue
            if e.get("ev") in ("agent_start", "agent_end") and not e.get("type"):
                continue  # internal agents, which the emitter no longer writes
            events.append(e)
    events.sort(key=lambda e: e["ts"])
    if not events:
        sys.exit("no events to replay")

    os.makedirs(args.target_dir, mode=0o700, exist_ok=True)
    path = os.path.join(args.target_dir, "events.jsonl")
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    clock, previous = time.time(), events[0]["ts"]
    for e in events:
        gap = min(max(e["ts"] - previous, 0), args.max_gap) / args.speed
        previous = e["ts"]
        time.sleep(gap)
        clock += gap
        os.write(fd, (json.dumps({**e, "ts": round(clock, 3)}, separators=(",", ":")) + "\n").encode())
    os.close(fd)


if __name__ == "__main__":
    main()
