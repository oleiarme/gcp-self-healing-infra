---
description: Test-Driven Development from Superpowers - write failing test first, minimal code to pass, refactor. No production code without a failing test.
---

# Test-Driven Development (from Superpowers)

Write the test first. Watch it fail. Write minimal code to pass.

## The Iron Law

NO PRODUCTION CODE WITHOUT A FAILING TEST FIRST.

Write code before the test? Delete it. Start over.

## Red-Green-Refactor

1. **RED** — Write one minimal failing test showing what should happen
2. **Verify RED** — Run test, confirm it fails for the right reason (feature missing, not typo)
3. **GREEN** — Write simplest code to pass the test. No extras.
4. **Verify GREEN** — Run test, confirm it passes. All other tests still pass.
5. **REFACTOR** — Clean up. Keep tests green. Don't add behavior.
6. **Repeat** — Next failing test for next feature.

## Rules

- One behavior per test
- Clear test name describing behavior
- Real code (no mocks unless unavoidable)
- Don't add features beyond what the test requires (YAGNI)
- Test passes immediately? You're testing existing behavior — fix test.

## Bug Fixes

Bug found? Write failing test reproducing it. Follow TDD cycle. Test proves fix and prevents regression. Never fix bugs without a test.

## Red Flags — STOP and Start Over

- Code before test
- Test passes immediately (never saw it fail)
- "I'll write tests after"
- "Too simple to test"
- Rationalizing "just this once"

## Exceptions

Ask user before skipping TDD for: throwaway prototypes, generated code, configuration files.
