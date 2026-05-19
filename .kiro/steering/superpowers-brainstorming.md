---
inclusion: auto
description: "Brainstorming methodology from Superpowers: explore context, ask questions one at a time, propose 2-3 approaches, present design incrementally, get approval before implementation."
---

# Brainstorming Ideas Into Designs (from Superpowers)

Help turn ideas into fully formed designs through natural collaborative dialogue.

## Hard Gate

Do NOT write any code, scaffold any project, or take any implementation action until you have presented a design and the user has approved it. This applies to EVERY project regardless of perceived simplicity.

## Anti-Pattern: "This Is Too Simple To Need A Design"

Every project goes through this process. A todo list, a single-function utility, a config change — all of them. "Simple" projects are where unexamined assumptions cause the most wasted work. The design can be short (a few sentences for truly simple projects), but you MUST present it and get approval.

## Process

1. **Explore project context** — check files, docs, recent commits
2. **Ask clarifying questions** — one at a time, understand purpose/constraints/success criteria
3. **Propose 2-3 approaches** — with trade-offs and your recommendation
4. **Present design** — in sections scaled to complexity, get user approval after each section
5. **Write design doc** — save and commit
6. **Spec self-review** — check for placeholders, contradictions, ambiguity, scope
7. **User reviews written spec** — ask user to review before proceeding
8. **Transition to implementation** — create implementation plan

## Key Principles

- **One question at a time** — Don't overwhelm with multiple questions
- **Multiple choice preferred** — Easier to answer than open-ended when possible
- **YAGNI ruthlessly** — Remove unnecessary features from all designs
- **Explore alternatives** — Always propose 2-3 approaches before settling
- **Incremental validation** — Present design, get approval before moving on

## Understanding the Idea

- Check current project state first (files, docs, recent commits)
- If request describes multiple independent subsystems — flag immediately, decompose first
- Ask questions one at a time to refine the idea
- Focus on: purpose, constraints, success criteria

## Exploring Approaches

- Propose 2-3 different approaches with trade-offs
- Lead with recommended option and explain why
- Present options conversationally

## Presenting the Design

- Scale each section to its complexity: few sentences if straightforward, up to 200-300 words if nuanced
- Ask after each section whether it looks right so far
- Cover: architecture, components, data flow, error handling, testing
- Be ready to go back and clarify

## Design for Isolation and Clarity

- Break system into smaller units with one clear purpose each
- Well-defined interfaces, testable independently
- For each unit: what does it do, how do you use it, what does it depend on?
- Smaller, well-bounded units are easier to reason about and edit reliably

## Working in Existing Codebases

- Explore current structure before proposing changes. Follow existing patterns.
- Where existing code has problems affecting the work, include targeted improvements as part of design
- Don't propose unrelated refactoring. Stay focused on current goal.

## Spec Self-Review

After writing spec:
1. **Placeholder scan:** Any "TBD", "TODO", incomplete sections? Fix them.
2. **Internal consistency:** Do sections contradict each other?
3. **Scope check:** Focused enough for single implementation plan?
4. **Ambiguity check:** Could any requirement be interpreted two ways? Pick one, make explicit.
