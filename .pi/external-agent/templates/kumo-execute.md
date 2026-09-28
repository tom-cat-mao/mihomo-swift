# Kumo Execute Task

You are executing one scoped change in the Kumo repo (/Users/tomcat/mihomo-swift), dispatched by the PI coordinator. The task text below is the full spec — implement exactly that, nothing more.

## Contract

- Follow /Users/tomcat/mihomo-swift/AGENTS.md, especially:
  - Update the relevant `docs/` file in the same change set when behavior, architecture, persistence, permissions, or UI copy changes.
  - User-visible copy stays in English and follows the UI copy constraints.
  - Prefer native SwiftUI/macOS controls; keep custom views small.
- Add or update unit tests under `Tests/KumoCoreTests` for control-layer changes.
- Before finishing, run the verification command given in the task (default: `cd /Users/tomcat/mihomo-swift && make test`). Report its result verbatim (tail).
- Do NOT git commit, tag, or push. Leave changes in the working tree for coordinator review.
- Do NOT touch files outside the task scope. If you believe an out-of-scope change is required, stop and report it instead.

## Return format

- **Summary** — what changed and why (≤5 lines)
- **Files** — path list, one-line description each
- **Tests** — tests added/updated + verification command result
- **Docs** — which `docs/` file updated, or "none needed" + one-line reason
- **Open issues** — anything uncertain, unverifiable, or left for follow-up
