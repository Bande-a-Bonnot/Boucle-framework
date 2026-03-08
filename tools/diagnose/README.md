# boucle diagnose

Agent operations intelligence for autonomous AI loops.

Analyzes signals, patterns, and response effectiveness to detect:

- **Regime phases** — Is the agent productive, stagnating, stuck, or failing?
- **Feedback loops** — Are responses amplifying the problems they're supposed to fix?
- **Response effectiveness** — Which responses actually reduce signal rates?
- **Chronic issues** — What keeps recurring and hasn't been addressed?

Built from 220+ real loops of autonomous agent operation.

## Install

Copy `diagnose.py` to your agent's `plugins/` directory:

```sh
cp diagnose.py /path/to/your-agent/plugins/diagnose.py
```

Or run standalone:

```sh
python3 diagnose.py --improve-dir /path/to/improve/
```

## Usage

As a Boucle plugin:

```sh
boucle diagnose
boucle diagnose --json
```

Standalone:

```sh
python3 diagnose.py
python3 diagnose.py --json
python3 diagnose.py --improve-dir ./my-agent/improve/
```

## Requirements

- Python 3.8+
- No dependencies (stdlib only)

## Input Format

Expects an `improve/` directory with:

### signals.jsonl

Append-only log. One JSON object per line:

```json
{"ts": "2026-03-08T06:00:00Z", "loop": 222, "type": "friction", "source": "manual", "summary": "API returned 404", "fingerprint": "api-404"}
```

Signal types: `friction`, `failure`, `waste`, `stagnation`, `silence`, `surprise`

### patterns.json

Fingerprint aggregates:

```json
{
  "api-404": {
    "type": "friction",
    "count": 5,
    "first_seen": "2026-03-07T10:00:00Z",
    "last_seen": "2026-03-08T06:00:00Z",
    "status": "active",
    "response_id": "gate-api-404.py"
  }
}
```

### scoreboard.json

Response effectiveness tracking:

```json
{
  "gate-api-404.py": {
    "signal_rate_before": 3.0,
    "signal_rate_after": 0.5,
    "status": "active"
  }
}
```

## Output

Human-readable by default. Use `--json` for structured output.

```
============================================================
BOUCLE DIAGNOSTICS
============================================================

Current regime: productive
Loops analyzed: 40

Loop efficiency: 55.0% productive, 45.0% problematic
  Breakdown: productive: 22, stagnating: 12, stuck: 4, failing: 2

Feedback loops: 5 detected, all resolved ✓

Response effectiveness: 6/12 responses reducing signals

Top recurring issues:
  [ 29x] zero-users-zero-revenue (active)
  [  8x] loop-silence (resolved)

RECOMMENDATIONS:
  🟠 [HIGH] 'zero-users-zero-revenue' occurred 29x and remains active. Root cause unaddressed.
```
