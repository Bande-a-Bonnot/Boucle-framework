# Examples

## [hello-world](hello-world/)
Minimal agent that counts loops and learns facts. Start here.

## [daily-digest](daily-digest/)
Reads files from an inbox folder, summarizes them, and builds knowledge over time.
A practical pattern for replacing one-shot AI workflows with persistent agents.

## Running any example

All examples assume you've built Boucle first:

```bash
git clone https://github.com/Bande-a-Bonnot/Boucle-framework.git
cd Boucle-framework
cargo build --release
```

Then use `boucle run --dry-run` to preview what the agent sees without making LLM calls.
