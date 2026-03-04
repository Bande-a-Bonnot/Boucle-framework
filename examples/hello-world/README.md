# Hello World Agent

A minimal Boucle agent that counts its own iterations and learns one fact per loop.

## Try it

```bash
# From the Boucle-framework root:
cargo build --release

# Create the agent
./target/release/boucle init --name hello-world
# This creates boucle.toml, system-prompt.md, and memory/STATE.md

# See what the agent will receive (no LLM call)
./target/release/boucle run --dry-run

# Run one loop iteration (requires `claude` CLI)
./target/release/boucle run
```

## What happens

Each iteration, the agent:
1. Reads its state from `memory/STATE.md`
2. Decides what to do (in this case: increment a counter, note something)
3. Updates `memory/STATE.md` with what it learned
4. Commits the changes to git

After 3 iterations, your state file might look like:

```markdown
# hello-world — State

## What I know
- Initialized: 2026-03-04
- Loop 1: Learned that Rust was created by Graydon Hoare
- Loop 2: Learned that the fastest bird is the peregrine falcon
- Loop 3: Learned that light takes 8 minutes to reach Earth from the Sun

## What I'm working on
- Counting loops and collecting facts
```

## Customizing

Edit `system-prompt.md` to change what the agent does each loop.
Edit `boucle.toml` to change the model, schedule interval, or memory settings.

## No LLM? Use dry-run

`boucle run --dry-run` prints the full context that would be sent to the LLM,
without making any API calls. Useful for understanding the loop structure.
