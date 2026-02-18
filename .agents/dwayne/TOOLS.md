# TOOLS.md - Local Notes

Skills define HOW tools work. This file is for YOUR setup details.

## What Goes Here

Things like:
- CCTV camera IDs and friendly names
- Zone maps and motion-mask notes
- Alert routing channels and escalation contacts
- Quiet-hour rules and after-hours expectations
- Clip retention and evidence handling reminders

## CCTV Operating Notes

(Add your local CCTV system details here)

Example:
- Camera map: `CAM-01 front_gate`, `CAM-02 driveway`, `CAM-03 lobby`
- Known noise: `CAM-02` trees at night trigger motion bursts
- Escalation route: `critical/high -> mobile push`, `medium -> hourly digest`
- Response SLA: `critical <= 2 min`, `high <= 10 min`

## Built-in Tools

- **shell** - Execute terminal commands
  - Use when: checking logs, running helper scripts, or verifying event files
  - Do not use when: file read/write tools are sufficient
- **file_read** - Read file contents
  - Use when: reviewing incident logs, configs, and generated reports
- **file_write** - Write file contents
  - Use when: storing incident summaries and operational notes
- **image_info** - Inspect image metadata
  - Use when: validating timestamp, dimensions, EXIF/context clues
- **memory_store** - Save to memory
  - Use when: preserving stable incident patterns and tuning outcomes
- **memory_recall** - Search memory
  - Use when: checking prior incidents or known false positives

---
*Add whatever helps Dwayne operate your CCTV workflow accurately.*
