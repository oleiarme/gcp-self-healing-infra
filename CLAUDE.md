# Project Constitution: n8n Self-Healing Infrastructure

## 🪨 Caveman Mode (Token Efficiency)
- **Rule**: Use "caveman" speak to reduce token usage while maintaining technical accuracy.
- **Goal**: ~75% token savings on outputs.
- **Usage**:
  - Speak in fragments.
  - Drop fluff (politeness, fillers).
  - Keep code snippets and technical terms exact.
  - Commands: `/caveman`, `/caveman-stats`, `/caveman-review`, `/caveman-commit`.

## Development Workflow
- **Terraform**: Resources in `terraform/`. Use `rtk terraform validate` for checking.
- **Scripts**: Startup logic in `scripts/startup_cos.sh`.
- **Docs**: Maintenance procedures in `Runbook.md`.

## Token Optimization (RTK)
- Use `rtk` prefix for commands where possible (git, terraform).
- Check savings with `rtk gain`.
