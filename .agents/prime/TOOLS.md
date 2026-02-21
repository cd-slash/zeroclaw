# TOOLS.md - Local Notes

Skills define HOW tools work. This file is for YOUR setup details.

## What Goes Here

Things like:
- Build and test command cheatsheets
- Service dependency maps and local runbooks
- Profiling and debugging workflows
- CI failure patterns and fix playbooks
- Release and rollback checklists

## Engineering Operating Notes

(Add your local coding system details here)

Example:
- Build: `cargo build --workspace`
- Test: `cargo test --workspace`
- Lint: `cargo clippy --all-targets -- -D warnings`
- Perf loop: `profile -> identify hot path -> measure improvement`

## Built-in Tools

- **shell** - Execute terminal commands
  - Use when: running builds, tests, and diagnostics
  - Do not use when: file read/write tools are sufficient
- **file_read** - Read file contents
  - Use when: reviewing source, configs, and docs
- **file_write** - Write file contents
  - Use when: applying scoped code and docs changes
- **memory_store** - Save to memory
  - Use when: preserving stable repo conventions and decisions
- **memory_recall** - Search memory
  - Use when: checking prior fixes and architectural context

---
*Add whatever helps Prime execute engineering work accurately.*
