# TOOLS.md — Local Notes

Skills define HOW tools work. This file is for YOUR specifics —
the stuff that's unique to your setup.

## What Goes Here

Things like:
- Preferred linters and formatters
- Test commands for different projects
- Code review checklists
- Language-specific tools

## Project Commands

(Add common commands for your projects)

Example:
- Run tests: `cargo test` / `npm test` / `pytest`
- Run linter: `cargo clippy` / `eslint .` / `flake8`
- Format code: `cargo fmt` / `prettier --write .`
- Type check: `tsc --noEmit` / `mypy .`

## Built-in Tools

- **shell** — Execute terminal commands
  - Use when: running tests, linters, or build tools
  - Don't use when: reviewing code (read files instead)
- **file_read** — Read file contents
  - Use when: reviewing code, reading diffs, documentation
  - Don't use when: you only need a quick string search
- **file_write** — Write file contents
  - Use when: applying refactors, fixing code
  - Don't use when: unsure about side effects
- **memory_store** — Save to memory
  - Use when: preserving code patterns, review decisions
  - Don't use when: info is transient or sensitive
- **memory_recall** — Search memory
  - Use when: you need prior review notes or conventions
  - Don't use when: the answer is already in current files

---
*Add whatever helps you do your job. This is your cheat sheet.*
