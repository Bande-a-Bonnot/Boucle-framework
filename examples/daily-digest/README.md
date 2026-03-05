# Daily Digest Agent

A practical Boucle agent that reads files from a drop folder and produces a daily summary.

## Try it

### Option 1: Copy this example

```bash
cp -r examples/daily-digest my-agent
cd my-agent
boucle run --dry-run    # Preview context (includes inbox/example-notes.txt)
boucle run              # Summarize the example file (requires claude CLI)
```

### Option 2: Start from scratch

```bash
boucle init --name daily-digest
mkdir inbox context.d
```

Then copy `system-prompt.md` and `context.d/inbox` from this example.

## What's included

```
daily-digest/
├── boucle.toml           # Agent config
├── system-prompt.md      # Agent instructions
├── memory/STATE.md       # Persistent state
├── context.d/inbox       # Script that lists inbox files in context
└── inbox/                # Drop folder for files to summarize
    └── example-notes.txt # Sample file (delete after testing)
```

## Usage

```bash
# Drop a file into the inbox
echo "Sprint retrospective: shipping velocity improved 20%" > inbox/retro.txt

# Run the agent
boucle run

# Check what it summarized
cat memory/STATE.md
```

## How it works

The `context.d/inbox` script runs before each iteration and injects the contents
of every file in `inbox/` into the agent's context. The agent reads them,
summarizes them, and updates its state.

This pattern — drop folder + scheduled agent + persistent memory — replaces
a surprising number of "AI workflow" tools. The agent accumulates knowledge
across runs, so by day 30 it has context that a one-shot prompt never will.
