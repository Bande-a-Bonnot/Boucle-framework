# Examples

Each example is a fully runnable agent — copy it, run it, modify it.

## [hello-world](hello-world/)
Minimal agent that counts loops and learns facts. Start here.

## [daily-digest](daily-digest/)
Reads files from an inbox folder, summarizes them, and builds knowledge over time.
A practical pattern for replacing one-shot AI workflows with persistent agents.

## Running any example

```bash
# Option 1: Download a release binary
# https://github.com/Bande-a-Bonnot/Boucle-framework/releases

# Option 2: Build from source
git clone https://github.com/Bande-a-Bonnot/Boucle-framework.git
cd Boucle-framework
cargo build --release

# Copy an example and run it
cp -r examples/hello-world my-agent
cd my-agent
boucle run --dry-run   # Preview context (no LLM call needed)
boucle run             # Run one iteration (requires the configured LLM CLI)
```

The checked-in examples use a Claude model in `boucle.toml`. Change
`agent.model` to a `gpt-*` model to run them through Codex instead.
