# TOOLS.md — Local Notes

Skills define HOW tools work. This file is for YOUR specifics —
the stuff that's unique to your setup.

## What Goes Here

Things like:
- SSH hosts and aliases
- Kubernetes cluster contexts
- Docker registry endpoints
- CI/CD platform details
- Preferred deployment strategies

## SSH Hosts

(Add your frequently used SSH hosts here)

Example:
- prod-server -> user@prod.example.com
- staging -> user@staging.example.com

## Kubernetes

(Add your cluster contexts)

Example:
- production -> prod-cluster
- staging -> staging-cluster
- local -> docker-desktop

## Docker Registries

(Add your registries)

Example:
- Docker Hub: docker.io/username
- ECR: 123456789.dkr.ecr.us-east-1.amazonaws.com
- GCR: gcr.io/project-id

## Built-in Tools

- **shell** — Execute terminal commands
  - Use when: running infrastructure commands, deployments, diagnostics
  - Always verify the result with a follow-up check (e.g., `docker ps` after starting a container)
  - Don't use when: a safer dedicated tool exists, or command is destructive without approval
- **file_read** — Read file contents
  - Use when: inspecting configs, manifests, logs
  - Use to verify changes after writing files
  - Don't use when: you only need a quick string search (prefer targeted search first)
- **file_write** — Write file contents
  - Use when: updating configurations, writing scripts
  - After writing, read back to confirm the change
  - Don't use when: unsure about side effects or when the file should remain user-owned
- **file_search** — Search across files
  - Use when: finding where something is defined or used
  - Essential for coordinating changes across multiple files
- **memory_store** — Save to memory
  - Use when: preserving infrastructure decisions, deployment notes, key context
  - Don't use when: info is transient, noisy, or sensitive without explicit need
- **memory_recall** — Search memory
  - Use when: you need prior infrastructure decisions, user preferences, or historical context
  - Don't use when: the answer is already in current files/conversation

## Execution Pattern

For every task:
1. **Before:** Document current state (what are we changing?)
2. **During:** Make the change with clear intent
3. **After:** Verify the change worked (run tests, check status, read results)
4. **Document:** Update memory with what was done and the outcome

---
*Add whatever helps you do your job. This is your cheat sheet.*
