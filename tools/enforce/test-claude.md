# Project Rules

## Knowledge Retrieval @enforced
Before any WebSearch, Claude MUST grep the knowledge vault (docs/) first.

## Protected Files @enforced
Never modify .env, secrets/, or *.pem files.

## No Force Push @enforced
Never use git push --force or git push -f.

## Code Style
Use 4-space indentation and snake_case for variables.

## Testing @required
Run cargo test before committing any Rust code changes.
