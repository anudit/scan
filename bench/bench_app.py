#!/usr/bin/env python3
"""
Launch a desktop data viewer on a file and sample CPU / memory / energy for the
whole process tree (main + helpers) using `top` (no sudo required).

Usage:
  python3 bench/bench_app.py --name tad \
      --cmd "/Applications/Tad.app/Contents/MacOS/Tad" \
      --match "Tad" --file /path/to/data.parquet --idle 30 --runs 3

Metrics per run:
  ready_s        seconds from launch until CPU settles (< settle_cpu % for settle_s)
  peak_mem_mb    peak sum of `top` MEM (phys footprint) across matched processes
  idle_mem_mb    mean summed MEM during the idle window after ready
  peak_cpu_pct   peak summed %CPU (100 = one core)
  load_cpu_s     integrated CPU-seconds from launch to ready
  idle_cpu_pct   mean summed %CPU during the idle window
  load_energy    integrated `top` POWER (energy-impact units * s) launch->ready
  idle_power     mean summed `top` POWER during idle window
  procs          number of matched processes at ready
  action_*       (with --action) cpu-s, mean/peak cpu %, peak mem while the action command runs
"""
import argparse, json, os, re, signal, statistics, subprocess, sys, time, threading

UNIT = {"B": 1 / 1048576, "K": 1 / 1024, "M": 1, "G": 1024, "T": 1048576}


def mem_mb(s):
    m = re.match(r"([\d.]+)([BKMGT])?", s)
    if not m:
        return 0.0
    return float(m.group(1)) * UNIT.get(m.group(2) or "B", 1)


def sample_stream():
    # -l 0: infinite samples, -s 1: 1 s interval. First sample's %CPU is invalid.
    p = subprocess.Popen(
        ["top", "-l", "0", "-s", "1", "-stats", "pid,command,cpu,mem,power", "-n", "400"],
        stdout=subprocess.PIPE, text=True, bufsize=1,
    )
    rows = None
    for line in p.stdout:
        if line.startswith("Processes:"):
            if rows is not None:
                yield rows
            rows = []
            continue
        if rows is None:
            continue
        if re.match(r"^\s*\d+\s", line):
            rows.append(line.rstrip("\n"))
    p.kill()


def process_tree(root_pid):
    """Follow launched process IDs, never another app sharing the same command name."""
    result = subprocess.run(["ps", "-axo", "pid=,ppid="], capture_output=True, text=True)
    parents = {}
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) == 2 and all(field.isdecimal() for field in fields):
            parents[int(fields[0])] = int(fields[1])
    selected = {root_pid}
    while True:
        expanded = selected | {pid for pid, parent in parents.items() if parent in selected}
        if expanded == selected:
            return selected
        selected = expanded


def parse(rows, match, root_pid):
    procs = []
    tree = process_tree(root_pid)
    for r in rows:
        # pid, command (may contain spaces), cpu, mem, power
        m = re.match(r"^\s*(\d+)\s+(.*?)\s+([\d.]+)\s+([\d.]+[BKMGT]?)[+-]?\s+([\d.]+)\s*$", r)
        if m and int(m.group(1)) in tree:
            procs.append((int(m.group(1)), m.group(2), float(m.group(3)), mem_mb(m.group(4)), float(m.group(5))))
    return procs


def run_once(a):
    subprocess.run(["pkill", "-f", a.kill_pattern], capture_output=True)
    time.sleep(2)
    stream = sample_stream()
    next(stream)  # discard first (invalid CPU) sample
    t0 = time.time()
    marker = {"first_rows_s": None}
    app = subprocess.Popen(a.cmd.split("|") + [a.file], stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, text=True, bufsize=1,
                           env={**os.environ, "SCAN_BENCHMARK": "1"})
    def read_markers():
        for line in app.stdout:
            if line.strip() == "SCAN_FIRST_ROWS" and marker["first_rows_s"] is None:
                marker["first_rows_s"] = round(time.time() - t0, 3)
    threading.Thread(target=read_markers, daemon=True).start()
    samples, ready_at, calm_since = [], None, None
    action_proc, action_t = None, [None, None]
    for rows in stream:
        t = time.time() - t0
        if app.poll() is not None:
            raise RuntimeError(f"Viewer exited with code {app.returncode}; no valid GUI benchmark collected")
        p = parse(rows, a.match, app.pid)
        cpu, mem, pwr = sum(x[2] for x in p), sum(x[3] for x in p), sum(x[4] for x in p)
        samples.append({"t": round(t, 2), "cpu": cpu, "mem": mem, "power": pwr, "procs": len(p)})
        if ready_at is None and t > 2 and len(p) > 0:
            if cpu < a.settle_cpu:
                calm_since = calm_since or t
                if t - calm_since >= a.settle_s:
                    ready_at = calm_since
            else:
                calm_since = None
        if a.action and ready_at is not None:
            if action_proc is None:
                action_t[0] = t
                action_proc = subprocess.Popen(a.action, shell=True)
                continue
            if action_t[1] is None:
                if action_proc.poll() is None:
                    continue
                action_t[1] = t
        if ready_at is not None and t - (action_t[1] or ready_at) >= a.settle_s + a.idle:
            break
        if t > a.timeout:
            ready_at = ready_at or t
            break
    subprocess.run(["pkill", "-f", a.kill_pattern], capture_output=True)
    app.wait(timeout=20)

    load = [s for s in samples if s["t"] <= ready_at]
    idle_from = (action_t[1] + a.settle_s) if action_t[1] else ready_at + a.settle_s
    idle = [s for s in samples if s["t"] > idle_from]
    act = [s for s in samples if action_t[1] and action_t[0] < s["t"] <= action_t[1]]
    extra = {}
    if act:
        extra = {
            "action_s": round(action_t[1] - action_t[0], 1),
            "action_cpu_s": round(sum(s["cpu"] for s in act) / 100, 2),
            "action_mean_cpu_pct": round(statistics.mean(s["cpu"] for s in act), 1),
            "action_peak_cpu_pct": round(max(s["cpu"] for s in act), 1),
            "action_peak_mem_mb": round(max(s["mem"] for s in act), 1),
        }
    return {
        "first_rows_s": marker["first_rows_s"],
        "ready_s": round(ready_at, 1),
        "peak_mem_mb": round(max(s["mem"] for s in samples), 1),
        "idle_mem_mb": round(statistics.mean(s["mem"] for s in idle), 1) if idle else None,
        "peak_cpu_pct": round(max(s["cpu"] for s in samples), 1),
        "load_cpu_s": round(sum(s["cpu"] for s in load) / 100, 2),
        "idle_cpu_pct": round(statistics.mean(s["cpu"] for s in idle), 2) if idle else None,
        "load_energy": round(sum(s["power"] for s in load), 1),
        "idle_power": round(statistics.mean(s["power"] for s in idle), 2) if idle else None,
        "procs": max(s["procs"] for s in samples),
        **extra,
        "samples": samples,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True)
    ap.add_argument("--cmd", required=True, help="executable; use | to separate extra args")
    ap.add_argument("--match", required=True, help="top COMMAND prefix to include")
    ap.add_argument("--kill-pattern", default=None)
    ap.add_argument("--file", required=True)
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--idle", type=float, default=30)
    ap.add_argument("--settle-cpu", type=float, default=5.0)
    ap.add_argument("--settle-s", type=float, default=3.0)
    ap.add_argument("--timeout", type=float, default=300)
    ap.add_argument("--out", default="bench/results")
    ap.add_argument("--action", default=None, help="shell command run once the app is ready")
    a = ap.parse_args()
    a.kill_pattern = a.kill_pattern or a.cmd.split("|")[0]
    os.makedirs(a.out, exist_ok=True)
    results = []
    for i in range(a.runs):
        r = run_once(a)
        results.append(r)
        print(f"[{a.name}] run {i+1}: " + json.dumps({k: v for k, v in r.items() if k != "samples"}), flush=True)
    keys = [k for k in results[0] if k != "samples"]
    summary = {k: (statistics.median(values) if values else None)
               for k in keys
               for values in [[r[k] for r in results if r[k] is not None]]}
    print(f"[{a.name}] median: {json.dumps(summary)}")
    with open(os.path.join(a.out, f"{a.name}.json"), "w") as f:
        json.dump({"name": a.name, "file": a.file, "cmd": a.cmd, "summary": summary, "runs": results}, f, indent=1)


if __name__ == "__main__":
    main()
