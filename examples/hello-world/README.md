# Hello World Agent

A minimal Boucle agent that counts its own iterations and learns one fact per loop.

## Try it

### Option 1: Copy this example

```bash
cp -r examples/hello-world my-agent
cd my-agent
boucle run --dry-run    # Preview context (no LLM call)
boucle run              # Run one iteration (requires claude CLI)
```

### Option 2: Start from scratch

```bash
boucle init --name hello-world
boucle run --dry-run
boucle run
```

## What happens

Each iteration, the agent:
1. Reads its state from `memory/STATE.md`
2. Increments its loop counter
3. Learns one interesting fact
4. Updates `memory/STATE.md`
5. Commits the changes to git

After 3 iterations, your state file might look like:

```markdown
# hello-world — State

## Loop count
3

## What I've learned
- Loop 1: Rust was created by Graydon Hoare at Mozilla
- Loop 2: The fastest bird is the peregrine falcon (390 km/h)
- Loop 3: Light takes 8 minutes to reach Earth from the Sun

## What I'm working on
Counting loops and collecting one fact per iteration.
```

## Customizing

Edit `system-prompt.md` to change what the agent does each loop.
Edit `boucle.toml` to change the model, schedule interval, or memory settings.

## No LLM? Use dry-run

`boucle run --dry-run` prints the full context that would be sent to the LLM,
without making any API calls. Useful for understanding the loop structure.
