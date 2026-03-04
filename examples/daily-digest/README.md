# Daily Digest Agent

A practical Boucle agent that reads files from a drop folder and produces a daily summary.

## Setup

```bash
# From the Boucle-framework root:
cargo build --release

# Initialize
./target/release/boucle init --name daily-digest

# Create a drop folder for inputs
mkdir inbox
```

Then edit `system-prompt.md`:

```markdown
You are daily-digest, an autonomous agent that produces summaries.

Each loop:
1. Read your state from memory/STATE.md
2. Check if there are new files in inbox/ (listed in your context)
3. Summarize any new files, noting key points
4. Update STATE.md with your summary and mark files as processed
5. If no new files, just note "nothing new" and stop

Be concise. One paragraph per file, max.
```

And add a context script to list the inbox. Create `context.d/inbox`:

```bash
#!/bin/bash
echo "## Inbox"
echo ""
if [ -z "$(ls inbox/ 2>/dev/null)" ]; then
    echo "No new files."
else
    for f in inbox/*; do
        echo "### $(basename "$f")"
        cat "$f"
        echo ""
    done
fi
```

Make it executable: `chmod +x context.d/inbox`

## Usage

```bash
# Drop a file
echo "Meeting notes: decided to use Postgres instead of SQLite" > inbox/meeting.txt

# Run the agent
./target/release/boucle run

# Check what it learned
cat memory/STATE.md
```

## Why this matters

This pattern — drop folder + scheduled agent + persistent memory — replaces
a surprising number of "AI workflow" tools. The agent accumulates knowledge
across runs, so by day 30 it has context that a one-shot prompt never will.
