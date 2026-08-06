#!/usr/bin/env python3
"""Check CML logs for ERROR/FATAL messages, honoring an allowlist.

Recursively scans a log directory for lines containing <ERROR> or <FATAL>,
drops lines matching any allowlist pattern, groups the survivors into faults
(maximal runs of consecutive lines in the same log file), deduplicates
identical faults and prints them sorted by occurrence count together with
the timestamps at which they occurred.

With --json-out the deduplicated faults are additionally written as JSON so a
later pipeline stage can aggregate the results of all test jobs: --merge takes
those per-job JSON files and prints only faults that did NOT occur in every
job (uniform faults are visible in each per-job report anyway).

Exit codes: 0 = no un-allowlisted errors, 1 = errors found (in merge mode:
faults that did not occur in all jobs), 2 = usage, allowlist or input problem.
The CI marks the stage UNSTABLE on any nonzero exit.
"""

import argparse
import json
import re
import sys
from pathlib import Path

SEVERITY_RE = re.compile(r"<ERROR>|<FATAL>")
# Timestamps shown per unique fault before summarizing the rest
TIMESTAMP_CAP = 10


def load_allowlist(path):
    """Return compiled patterns; '#' comments and blank lines are skipped."""
    patterns = []
    if not path.is_file():
        return patterns
    for nr, raw in enumerate(path.read_text(errors="replace").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        try:
            patterns.append(re.compile(line))
        except re.error as e:
            print(f"ERROR: bad allowlist pattern at {path}:{nr}: {e} - "
                  "check allowlist syntax", file=sys.stderr)
            sys.exit(2)
    return patterns


def scan_logs(log_dir, allow_patterns):
    """Yield (relpath, lineno, content) for un-allowlisted ERROR/FATAL lines.

    A line is suppressed if any allowlist pattern matches anywhere in
    'relpath:lineno:content' (the format grep -rn produced historically).
    """
    for f in sorted(p for p in log_dir.rglob("*") if p.is_file()):
        relpath = f.relative_to(log_dir)
        for lineno, content in enumerate(
                f.read_text(errors="replace").splitlines(), 1):
            if not SEVERITY_RE.search(content):
                continue
            grep_line = f"{relpath}:{lineno}:{content}"
            if any(p.search(grep_line) for p in allow_patterns):
                continue
            yield relpath, lineno, content


def group_faults(records):
    """Group records into faults and deduplicate them.

    A fault is a maximal run of consecutive line numbers within one file.
    Two faults are the same if their lines match from the <ERROR>/<FATAL>
    tag onward (timestamp and [pid] prefix ignored, so faults recur across
    cmld restarts and log files).

    Returns ({fault_key: [timestamps]}, total_message_count).
    """
    faults = {}
    total = 0
    key = []
    prev_path, prev_lineno, first_ts = None, None, None

    def flush():
        if key:
            faults.setdefault(tuple(key), []).append(first_ts)
            key.clear()

    for relpath, lineno, content in records:
        total += 1
        if relpath != prev_path or lineno != prev_lineno + 1:
            flush()
            first_ts = content.split(None, 1)[0]
        key.append(content[SEVERITY_RE.search(content).start():])
        prev_path, prev_lineno = relpath, lineno
    flush()
    return faults, total


def report(faults, total):
    occurrences = sum(len(ts) for ts in faults.values())
    print("CML wrote ERROR/FATAL log messages - marking stage UNSTABLE:")
    print(f"Total: {total} ERROR/FATAL messages, {occurrences} fault "
          f"occurrences, {len(faults)} unique faults")
    # most frequent first; sort is stable, ties keep first-seen order
    for key, timestamps in sorted(faults.items(), key=lambda kv: -len(kv[1])):
        print(f"\n===>> {len(timestamps)}x CML FAULT: <<===")
        for line in key:
            print(line)
        shown = timestamps[:TIMESTAMP_CAP]
        print(f"    at: {shown[0]}")
        for ts in shown[1:]:
            print(f"        {ts}")
        if len(timestamps) > TIMESTAMP_CAP:
            print(f"        ... and {len(timestamps) - TIMESTAMP_CAP} more, "
                  f"last at {timestamps[-1]}")


def print_severity_table(sev_counts):
    """Print message counts as a table: rows ERROR/FATAL, one column per job."""
    jobs = sorted(sev_counts)
    label_width = max(len(sev) for sev in ("ERROR", "FATAL"))
    widths = [max(len(job), 6) for job in jobs]
    print(" " * label_width
          + "".join(f"  {job:>{w}}" for job, w in zip(jobs, widths)))
    for sev in ("ERROR", "FATAL"):
        print(f"{sev:<{label_width}}"
              + "".join(f"  {sev_counts[job][sev]:>{w}}"
                        for job, w in zip(jobs, widths)))


def merge_reports(paths):
    """Summarize per-job JSON reports, hiding faults common to all jobs."""
    jobs = []
    by_fault = {}    # fault key -> {job: occurrence count}
    sev_counts = {}  # job -> {"ERROR": messages, "FATAL": messages}
    for p in paths:
        try:
            data = json.loads(Path(p).read_text(errors="replace"))
            job = data["job"]
            faults = [(tuple(f["lines"]), len(f["timestamps"]))
                      for f in data["faults"]]
        except (OSError, ValueError, KeyError, TypeError) as e:
            print(f"ERROR: cannot read per-job report {p}: {e}", file=sys.stderr)
            return 2
        jobs.append(job)
        counts = sev_counts.setdefault(job, {"ERROR": 0, "FATAL": 0})
        for key, count in faults:
            by_fault.setdefault(key, {})[job] = count
            for line in key:
                sev = "FATAL" if line.startswith("<FATAL>") else "ERROR"
                counts[sev] += count

    if not jobs:
        print("No per-job CML error reports found - nothing to summarize")
        return 0

    differing = {k: v for k, v in by_fault.items() if set(v) != set(jobs)}
    for key, per_job in sorted(differing.items(),
                               key=lambda kv: -sum(kv[1].values())):
        hits = ", ".join(f"{job}: {n}x" for job, n in sorted(per_job.items()))
        print(f"\n===>> CML FAULT in {len(per_job)}/{len(jobs)} jobs "
              f"({hits}) <<===")
        for line in key:
            print(line)

    def print_hline():
        print(f"{'='*100}")
        print(f"{'='*100}")

    print('\n\n')
    print_hline()
    print(f"CML error summary across {len(jobs)} test jobs: "
          f"{', '.join(sorted(jobs))}")
    print(f"{len(by_fault)} unique faults total, "
          f"{len(by_fault) - len(differing)} occurred in all jobs (omitted), "
          f"{len(differing)} did not:")
    print()
    print_severity_table(sev_counts)
    print_hline()
    print('\nFor the full per-job reports see the '
          '"Check for CML ERROR/FATAL logs" step in each test stage.')
    return 1 if differing else 0


def write_json(path, job_name, faults):
    data = {"job": job_name,
            "faults": [{"lines": list(key), "timestamps": timestamps}
                       for key, timestamps in faults.items()]}
    path.write_text(json.dumps(data, indent=1))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log-dir", type=Path,
                        help="directory containing the CML logs")
    parser.add_argument("--allowlist", type=Path,
                        help="file with one regex per line for expected errors")
    parser.add_argument("--json-out", type=Path,
                        help="also write the faults as JSON for --merge")
    parser.add_argument("--job-name",
                        help="job name stored in the --json-out report")
    parser.add_argument("--merge", nargs="*", metavar="JSON",
                        help="summarize per-job JSON reports instead of "
                             "scanning logs; hides faults common to all jobs")
    args = parser.parse_args()

    if args.merge is not None:
        if args.log_dir or args.allowlist or args.json_out or args.job_name:
            parser.error("--merge cannot be combined with scan-mode options")
        return merge_reports(args.merge)

    if not args.log_dir or not args.allowlist:
        parser.error("--log-dir and --allowlist are required to scan logs")
    if bool(args.json_out) != bool(args.job_name):
        parser.error("--json-out and --job-name must be used together")
    if not args.log_dir.is_dir():
        print(f"ERROR: log dir {args.log_dir} does not exist", file=sys.stderr)
        return 2

    allow_patterns = load_allowlist(args.allowlist)
    faults, total = group_faults(scan_logs(args.log_dir, allow_patterns))

    if args.json_out:
        # written also for clean runs: an empty report makes faults of other
        # jobs count as "not in all jobs" in the merged summary
        write_json(args.json_out, args.job_name, faults)

    if not faults:
        print("No un-allowlisted CML ERROR/FATAL messages found")
        return 0
    report(faults, total)
    return 1


if __name__ == "__main__":
    sys.exit(main())
