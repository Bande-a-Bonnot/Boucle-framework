#!/usr/bin/env python3
"""Tests for boucle diagnose."""
import json
import os
import sys
import tempfile
import shutil

# Add parent to path for import
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import diagnose

def setup_temp_improve(signals=None, patterns=None, scoreboard=None):
    """Create a temporary improve/ directory with test data."""
    tmpdir = tempfile.mkdtemp()
    improve = os.path.join(tmpdir, "improve")
    os.makedirs(improve)

    if signals:
        with open(os.path.join(improve, "signals.jsonl"), "w") as f:
            for s in signals:
                f.write(json.dumps(s) + "\n")

    if patterns:
        with open(os.path.join(improve, "patterns.json"), "w") as f:
            json.dump(patterns, f)

    if scoreboard:
        with open(os.path.join(improve, "scoreboard.json"), "w") as f:
            json.dump(scoreboard, f)

    return tmpdir, improve


def cleanup(tmpdir):
    shutil.rmtree(tmpdir)


def test_empty_signals():
    """No signals → error in report."""
    tmpdir, improve = setup_temp_improve()
    diagnose.IMPROVE_DIR = improve
    report = diagnose.diagnose()
    assert "error" in report, "Expected error when no signals"
    cleanup(tmpdir)
    print("✓ test_empty_signals")


def test_productive_loop():
    """Loops with no problem signals don't exist in signal log (by design)."""
    signals = [
        {"ts": "2026-03-01T10:00:00Z", "loop": 1, "type": "friction", "source": "test", "summary": "test", "fingerprint": "fp1"},
    ]
    tmpdir, improve = setup_temp_improve(signals=signals)
    diagnose.IMPROVE_DIR = improve
    report = diagnose.diagnose()
    assert report["signals_analyzed"] == 1
    assert report["regime"]["total_loops"] == 1
    cleanup(tmpdir)
    print("✓ test_productive_loop")


def test_classify_loops_failing():
    """Loop with failure signal → classified as failing."""
    signals = [
        {"ts": "2026-03-01T10:00:00Z", "loop": 1, "type": "failure", "source": "test", "summary": "crash", "fingerprint": "crash"},
    ]
    tmpdir, improve = setup_temp_improve(signals=signals)
    diagnose.IMPROVE_DIR = improve
    classified = diagnose.classify_loops(signals)
    assert classified[1]["regime"] == "failing"
    cleanup(tmpdir)
    print("✓ test_classify_loops_failing")


def test_classify_loops_stagnating():
    """Loop with waste signal → stagnating."""
    signals = [
        {"ts": "2026-03-01T10:00:00Z", "loop": 1, "type": "waste", "source": "test", "summary": "spinning", "fingerprint": "spin"},
    ]
    classified = diagnose.classify_loops(signals)
    assert classified[1]["regime"] == "stagnating"
    print("✓ test_classify_loops_stagnating")


def test_classify_loops_stuck():
    """Same fingerprints repeating across >3 loops → stuck."""
    signals = []
    for loop_num in range(1, 6):
        signals.append({"ts": f"2026-03-01T{10+loop_num}:00:00Z", "loop": loop_num, "type": "friction", "source": "test", "summary": "same", "fingerprint": "stuck-fp"})
        signals.append({"ts": f"2026-03-01T{10+loop_num}:00:01Z", "loop": loop_num, "type": "friction", "source": "test", "summary": "same2", "fingerprint": "stuck-fp2"})
        signals.append({"ts": f"2026-03-01T{10+loop_num}:00:02Z", "loop": loop_num, "type": "friction", "source": "test", "summary": "same3", "fingerprint": "stuck-fp3"})

    classified = diagnose.classify_loops(signals)
    # Later loops should be classified as stuck (same fingerprints repeating)
    assert classified[5]["regime"] == "stuck", f"Expected stuck, got {classified[5]['regime']}"
    print("✓ test_classify_loops_stuck")


def test_detect_feedback_loops():
    """Response that amplifies signals → detected as feedback loop."""
    patterns = {
        "fp1": {"type": "friction", "count": 10, "status": "active", "response_id": "gate-fp1.py"}
    }
    scoreboard = {
        "gate-fp1.py": {"signal_rate_before": 1.0, "signal_rate_after": 5.0, "status": "active"}
    }
    signals = [{"ts": "2026-03-01T10:00:00Z", "loop": 1, "type": "friction", "source": "test", "summary": "x", "fingerprint": "fp1"}]

    fls = diagnose.detect_feedback_loops(signals, patterns, scoreboard)
    assert len(fls) == 1
    assert fls[0]["amplification_ratio"] == 5.0
    print("✓ test_detect_feedback_loops")


def test_no_feedback_loops_when_effective():
    """Response that reduces signals → no feedback loop."""
    patterns = {
        "fp1": {"type": "friction", "count": 10, "status": "active", "response_id": "gate-fp1.py"}
    }
    scoreboard = {
        "gate-fp1.py": {"signal_rate_before": 5.0, "signal_rate_after": 1.0, "status": "active"}
    }
    signals = []
    fls = diagnose.detect_feedback_loops(signals, patterns, scoreboard)
    assert len(fls) == 0
    print("✓ test_no_feedback_loops_when_effective")


def test_response_effectiveness():
    """Effective response shows >10% reduction."""
    scoreboard = {
        "good-gate.py": {"signal_rate_before": 10.0, "signal_rate_after": 2.0, "status": "active"},
        "bad-gate.py": {"signal_rate_before": 10.0, "signal_rate_after": 9.5, "status": "active"},
    }
    results = diagnose.analyze_response_effectiveness(scoreboard)
    assert results["good-gate.py"]["effective"] is True
    assert results["bad-gate.py"]["effective"] is False
    assert results["good-gate.py"]["reduction_pct"] == 80.0
    print("✓ test_response_effectiveness")


def test_top_recurring_issues():
    """Returns issues sorted by count, excludes resolved."""
    patterns = {
        "fp-resolved": {"type": "friction", "count": 100, "status": "resolved"},
        "fp-chronic": {"type": "failure", "count": 29, "status": "active"},
        "fp-minor": {"type": "waste", "count": 2, "status": "active"},
    }
    issues = diagnose.top_recurring_issues(patterns)
    assert len(issues) == 2  # resolved excluded
    assert issues[0]["fingerprint"] == "fp-chronic"
    assert issues[0]["count"] == 29
    print("✓ test_top_recurring_issues")


def test_recommendations_feedback_loop():
    """Active feedback loop → critical recommendation."""
    feedback_loops = [{"fingerprint": "fp1", "response_id": "gate.py", "amplification_ratio": 5.0, "status": "active", "before_rate": 1, "after_rate": 5}]
    recs = diagnose.generate_recommendations({}, {}, feedback_loops, [])
    assert any(r["priority"] == "critical" for r in recs)
    print("✓ test_recommendations_feedback_loop")


def test_recommendations_high_problem_rate():
    """High problem rate → high priority recommendation."""
    efficiency = {"productive_pct": 10, "problem_pct": 90}
    recs = diagnose.generate_recommendations(efficiency, {}, [], [])
    assert any(r["priority"] == "high" and "90" in r["message"] for r in recs)
    print("✓ test_recommendations_high_problem_rate")


def test_recommendations_chronic_issue():
    """Chronic issue → high priority recommendation."""
    issues = [{"fingerprint": "chronic", "count": 29, "status": "active", "type": "failure"}]
    recs = diagnose.generate_recommendations({}, {}, [], issues)
    assert any("chronic" in r["message"] for r in recs)
    print("✓ test_recommendations_chronic_issue")


def test_format_human_readable():
    """Human-readable output contains key sections."""
    report = {
        "regime": {"current": "productive", "total_loops": 10, "transitions": [], "phase_lengths": {}},
        "efficiency": {"productive_pct": 80, "problem_pct": 20, "by_regime": {"productive": 8, "failing": 2}},
        "feedback_loops": [],
        "response_effectiveness": {},
        "top_issues": [],
        "recommendations": [],
    }
    output = diagnose.format_human_readable(report)
    assert "BOUCLE DIAGNOSTICS" in output
    assert "productive" in output
    assert "80" in output
    print("✓ test_format_human_readable")


def test_json_output():
    """Full pipeline produces valid JSON."""
    signals = [
        {"ts": "2026-03-01T10:00:00Z", "loop": 1, "type": "friction", "source": "test", "summary": "test", "fingerprint": "fp1"},
        {"ts": "2026-03-01T11:00:00Z", "loop": 2, "type": "failure", "source": "test", "summary": "crash", "fingerprint": "fp2"},
    ]
    tmpdir, improve = setup_temp_improve(
        signals=signals,
        patterns={"fp1": {"type": "friction", "count": 5, "status": "active"}},
        scoreboard={},
    )
    diagnose.IMPROVE_DIR = improve
    report = diagnose.diagnose()
    json_str = json.dumps(report)
    parsed = json.loads(json_str)
    assert "timestamp" in parsed
    assert parsed["signals_analyzed"] == 2
    cleanup(tmpdir)
    print("✓ test_json_output")


def test_recovering_regime():
    """Loop after failure with no failure signals → recovering."""
    signals = [
        {"ts": "2026-03-01T10:00:00Z", "loop": 1, "type": "failure", "source": "test", "summary": "crash", "fingerprint": "fp1"},
        {"ts": "2026-03-01T11:00:00Z", "loop": 2, "type": "friction", "source": "test", "summary": "minor", "fingerprint": "fp2"},
    ]
    classified = diagnose.classify_loops(signals)
    assert classified[1]["regime"] == "failing"
    assert classified[2]["regime"] == "recovering"
    print("✓ test_recovering_regime")


if __name__ == "__main__":
    tests = [
        test_empty_signals,
        test_productive_loop,
        test_classify_loops_failing,
        test_classify_loops_stagnating,
        test_classify_loops_stuck,
        test_detect_feedback_loops,
        test_no_feedback_loops_when_effective,
        test_response_effectiveness,
        test_top_recurring_issues,
        test_recommendations_feedback_loop,
        test_recommendations_high_problem_rate,
        test_recommendations_chronic_issue,
        test_format_human_readable,
        test_json_output,
        test_recovering_regime,
    ]

    passed = 0
    failed = 0
    for test in tests:
        try:
            test()
            passed += 1
        except Exception as e:
            print(f"✗ {test.__name__}: {e}")
            failed += 1

    print(f"\n{passed} passed, {failed} failed out of {len(tests)} tests")
    sys.exit(1 if failed else 0)
