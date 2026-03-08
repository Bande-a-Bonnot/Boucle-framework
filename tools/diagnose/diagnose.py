#!/usr/bin/env python3
# description: Agent operations intelligence — analyze loop health and detect problems
"""
boucle diagnose — Agent Operations Intelligence

Analyzes operational data from autonomous agent loops to produce
actionable diagnostics. Detects regime phases, feedback loops,
response effectiveness, and generates recommendations.

Built from 220+ real loops of autonomous operational data.

Usage as plugin:  boucle diagnose [--json]
Usage standalone: python3 diagnose.py [--json] [--improve-dir PATH]

Expects an improve/ directory with:
  - signals.jsonl  (append-only signal log)
  - patterns.json  (fingerprint → count, status, response_id)
  - scoreboard.json (response effectiveness tracking)
"""
import json
import os
import sys
from collections import defaultdict, Counter
from datetime import datetime, timedelta

# Resolve improve/ directory: env var > CLI arg > default
AGENT_ROOT = os.environ.get("BOUCLE_ROOT", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
IMPROVE_DIR = os.environ.get("BOUCLE_IMPROVE_DIR", os.path.join(AGENT_ROOT, "improve"))


def load_signals():
    """Load all signals from the append-only log."""
    signals = []
    path = os.path.join(IMPROVE_DIR, "signals.jsonl")
    if not os.path.exists(path):
        return signals
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    signals.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    return signals


def load_json(filename):
    """Load a JSON file from the improve directory."""
    path = os.path.join(IMPROVE_DIR, filename)
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        return json.load(f)


def classify_loops(signals):
    """Classify each loop into a regime based on signal distribution.

    Regimes:
    - productive: No friction/failure/waste signals
    - stagnating: Mostly waste or silence signals
    - failing: Has failure signals
    - recovering: Had failures, then productive signals
    - stuck: Same fingerprints repeating across multiple loops
    """
    loops = defaultdict(list)
    for s in signals:
        loop_num = s.get("loop")
        if loop_num is not None:
            loops[loop_num].append(s)

    classified = {}
    prev_regime = None
    for loop_num in sorted(loops.keys()):
        sigs = loops[loop_num]
        types = Counter(s.get("type", "unknown") for s in sigs)
        fingerprints = [s.get("fingerprint", "") for s in sigs]

        if types.get("failure", 0) > 0:
            regime = "failing"
        elif types.get("waste", 0) > 0 or types.get("stagnation", 0) > 0:
            regime = "stagnating"
        elif types.get("silence", 0) > 0 and len(types) == 1:
            regime = "stagnating"
        elif prev_regime == "failing" and types.get("failure", 0) == 0:
            regime = "recovering"
        else:
            regime = "productive"

        # Check for stuck: same fingerprints in previous 3 loops
        recent_fps = set()
        for prev_loop in range(max(1, loop_num - 3), loop_num):
            if prev_loop in loops:
                for s in loops[prev_loop]:
                    recent_fps.add(s.get("fingerprint", ""))
        current_fps = set(fingerprints)
        overlap = current_fps & recent_fps
        if len(overlap) > 2 and regime != "failing":
            regime = "stuck"

        classified[loop_num] = {
            "regime": regime,
            "signal_count": len(sigs),
            "types": dict(types),
            "fingerprints": fingerprints,
        }
        prev_regime = regime

    return classified


def detect_regimes(classified_loops):
    """Detect regime transitions and current phase."""
    if not classified_loops:
        return {"current": "unknown", "transitions": [], "phase_lengths": {}}

    regimes_seq = [(loop_num, data["regime"]) for loop_num, data in sorted(classified_loops.items())]

    transitions = []
    phase_lengths = defaultdict(int)
    for i, (loop_num, regime) in enumerate(regimes_seq):
        phase_lengths[regime] += 1
        if i > 0 and regimes_seq[i - 1][1] != regime:
            transitions.append({
                "from": regimes_seq[i - 1][1],
                "to": regime,
                "at_loop": loop_num,
            })

    current = regimes_seq[-1][1] if regimes_seq else "unknown"
    return {
        "current": current,
        "transitions": transitions[-10:],  # Last 10 transitions
        "phase_lengths": dict(phase_lengths),
        "total_loops": len(regimes_seq),
    }


def analyze_response_effectiveness(scoreboard):
    """Analyze which responses are working and which aren't."""
    results = {}
    for resp_id, data in scoreboard.items():
        if isinstance(data, dict):
            before = data.get("signal_rate_before", 0)
            after = data.get("signal_rate_after", 0)
            if before > 0:
                reduction = (before - after) / before
            else:
                reduction = 0
            results[resp_id] = {
                "reduction_pct": round(reduction * 100, 1),
                "effective": reduction > 0.1,  # >10% reduction = effective
                "before_rate": before,
                "after_rate": after,
                "status": data.get("status", "unknown"),
            }
    return results


def detect_feedback_loops(signals, patterns, scoreboard):
    """Detect cases where a response is generating MORE signals than it suppresses."""
    feedback_loops = []

    for fp, pattern in patterns.items():
        if not isinstance(pattern, dict):
            continue
        response_id = pattern.get("response_id")
        if not response_id:
            continue

        # Check scoreboard
        if response_id in scoreboard:
            sb_data = scoreboard[response_id]
            if isinstance(sb_data, dict):
                before = sb_data.get("signal_rate_before", 0)
                after = sb_data.get("signal_rate_after", 0)
                if after > before and before > 0:
                    amplification = after / before
                    feedback_loops.append({
                        "fingerprint": fp,
                        "response_id": response_id,
                        "amplification_ratio": round(amplification, 1),
                        "before_rate": before,
                        "after_rate": after,
                        "status": pattern.get("status", "unknown"),
                    })

    return feedback_loops


def compute_loop_efficiency(signals, classified_loops):
    """Compute what percentage of loops are productive vs problematic."""
    if not classified_loops:
        return {"productive_pct": 0, "problem_pct": 0, "total": 0}

    total = len(classified_loops)
    productive = sum(1 for d in classified_loops.values() if d["regime"] == "productive")
    problem = sum(1 for d in classified_loops.values() if d["regime"] in ("failing", "stuck", "stagnating"))

    return {
        "productive_pct": round(productive / total * 100, 1) if total else 0,
        "problem_pct": round(problem / total * 100, 1) if total else 0,
        "total": total,
        "by_regime": dict(Counter(d["regime"] for d in classified_loops.values())),
    }


def top_recurring_issues(patterns):
    """Find the most chronic unresolved issues."""
    issues = []
    for fp, data in patterns.items():
        if not isinstance(data, dict):
            continue
        count = data.get("count", 0)
        status = data.get("status", "unknown")
        if status not in ("resolved", "archived"):
            issues.append({
                "fingerprint": fp,
                "count": count,
                "type": data.get("type", "unknown"),
                "status": status,
                "first_seen": data.get("first_seen", "?"),
                "last_seen": data.get("last_seen", "?"),
            })
    issues.sort(key=lambda x: x["count"], reverse=True)
    return issues[:10]


def generate_recommendations(efficiency, effectiveness, feedback_loops, issues):
    """Generate actionable recommendations based on analysis."""
    recs = []

    # Feedback loop recommendations
    for fl in feedback_loops:
        if fl["status"] != "resolved":
            recs.append({
                "priority": "critical",
                "type": "feedback_loop",
                "message": f"Response '{fl['response_id']}' amplifies signals {fl['amplification_ratio']}x for '{fl['fingerprint']}'. Disable or redesign.",
            })

    # High problem rate
    if efficiency.get("problem_pct", 0) > 50:
        recs.append({
            "priority": "high",
            "type": "efficiency",
            "message": f"{efficiency['problem_pct']}% of loops have problems. Review signal sources and response coverage.",
        })

    # Ineffective responses
    for resp_id, data in effectiveness.items():
        if not data["effective"] and data["before_rate"] > 0:
            recs.append({
                "priority": "medium",
                "type": "ineffective_response",
                "message": f"Response '{resp_id}' shows only {data['reduction_pct']}% signal reduction. Consider replacing.",
            })

    # Chronic issues
    for issue in issues[:3]:
        if issue["count"] > 10:
            recs.append({
                "priority": "high",
                "type": "chronic_issue",
                "message": f"'{issue['fingerprint']}' occurred {issue['count']}x and remains {issue['status']}. Root cause unaddressed.",
            })

    recs.sort(key=lambda r: {"critical": 0, "high": 1, "medium": 2, "low": 3}.get(r["priority"], 4))
    return recs


def format_human_readable(report):
    """Format the diagnostic report for human consumption."""
    lines = []
    lines.append("=" * 60)
    lines.append("BOUCLE DIAGNOSTICS")
    lines.append("=" * 60)
    lines.append("")

    # Regime
    regime = report.get("regime", {})
    lines.append(f"Current regime: {regime.get('current', '?')}")
    lines.append(f"Loops analyzed: {regime.get('total_loops', 0)}")
    lines.append("")

    # Efficiency
    eff = report.get("efficiency", {})
    lines.append(f"Loop efficiency: {eff.get('productive_pct', 0)}% productive, {eff.get('problem_pct', 0)}% problematic")
    by_regime = eff.get("by_regime", {})
    if by_regime:
        regime_str = ", ".join(f"{k}: {v}" for k, v in sorted(by_regime.items(), key=lambda x: -x[1]))
        lines.append(f"  Breakdown: {regime_str}")
    lines.append("")

    # Feedback loops
    fls = report.get("feedback_loops", [])
    active_fls = [fl for fl in fls if fl.get("status") != "resolved"]
    if active_fls:
        lines.append(f"ACTIVE FEEDBACK LOOPS: {len(active_fls)}")
        for fl in active_fls:
            lines.append(f"  ⚠ {fl['fingerprint']}: {fl['response_id']} amplifies {fl['amplification_ratio']}x")
    else:
        lines.append(f"Feedback loops: {len(fls)} detected, all resolved ✓")
    lines.append("")

    # Response effectiveness
    eff_data = report.get("response_effectiveness", {})
    if eff_data:
        effective = sum(1 for d in eff_data.values() if d.get("effective"))
        total = len(eff_data)
        lines.append(f"Response effectiveness: {effective}/{total} responses reducing signals")
    lines.append("")

    # Top issues
    issues = report.get("top_issues", [])
    if issues:
        lines.append("Top recurring issues:")
        for issue in issues[:5]:
            lines.append(f"  [{issue['count']:3d}x] {issue['fingerprint']} ({issue['status']})")
    lines.append("")

    # Recommendations
    recs = report.get("recommendations", [])
    if recs:
        lines.append("RECOMMENDATIONS:")
        for rec in recs:
            icon = {"critical": "🔴", "high": "🟠", "medium": "🟡", "low": "🟢"}.get(rec["priority"], "·")
            lines.append(f"  {icon} [{rec['priority'].upper()}] {rec['message']}")
    else:
        lines.append("No recommendations — operations healthy.")
    lines.append("")

    return "\n".join(lines)


def diagnose():
    """Run full diagnostic analysis and return structured report."""
    signals = load_signals()
    patterns = load_json("patterns.json")
    scoreboard = load_json("scoreboard.json")

    if not signals:
        return {"error": "No signals found. Is improve/signals.jsonl present?", "improve_dir": IMPROVE_DIR}

    classified = classify_loops(signals)
    regime = detect_regimes(classified)
    effectiveness = analyze_response_effectiveness(scoreboard)
    feedback_loops = detect_feedback_loops(signals, patterns, scoreboard)
    efficiency = compute_loop_efficiency(signals, classified)
    issues = top_recurring_issues(patterns)
    recommendations = generate_recommendations(efficiency, effectiveness, feedback_loops, issues)

    return {
        "timestamp": datetime.utcnow().isoformat() + "Z",
        "signals_analyzed": len(signals),
        "improve_dir": IMPROVE_DIR,
        "regime": regime,
        "efficiency": efficiency,
        "response_effectiveness": effectiveness,
        "feedback_loops": feedback_loops,
        "top_issues": issues,
        "recommendations": recommendations,
    }


def main():
    # Allow --improve-dir override
    for i, arg in enumerate(sys.argv[1:], 1):
        if arg == "--improve-dir" and i < len(sys.argv) - 1:
            global IMPROVE_DIR
            IMPROVE_DIR = sys.argv[i + 1]

    report = diagnose()

    if "--json" in sys.argv:
        print(json.dumps(report, indent=2))
    else:
        if "error" in report:
            print(f"Error: {report['error']}")
            print(f"Looked in: {report['improve_dir']}")
            sys.exit(1)
        print(format_human_readable(report))


if __name__ == "__main__":
    main()
