---
inclusion: auto
description: "Systematic debugging from Superpowers: 4-phase process — root cause investigation, pattern analysis, hypothesis testing, implementation. No fixes without root cause first."
---

# Systematic Debugging (from Superpowers)

NO FIXES WITHOUT ROOT CAUSE INVESTIGATION FIRST.

## The Four Phases

### Phase 1: Root Cause Investigation

BEFORE attempting ANY fix:

1. Read error messages carefully — stack traces, line numbers, error codes
2. Reproduce consistently — exact steps, every time?
3. Check recent changes — git diff, new deps, config changes
4. Gather evidence in multi-component systems — log at each boundary
5. Trace data flow — where does bad value originate? Keep tracing up.

### Phase 2: Pattern Analysis

1. Find working examples in same codebase
2. Compare against references — read completely, don't skim
3. Identify differences between working and broken
4. Understand dependencies and assumptions

### Phase 3: Hypothesis and Testing

1. Form single hypothesis: "X is root cause because Y"
2. Test minimally — smallest possible change, one variable
3. Verify — worked? → Phase 4. Didn't? → new hypothesis. Don't stack fixes.

### Phase 4: Implementation

1. Create failing test case (use TDD)
2. Implement single fix — ONE change, no "while I'm here" improvements
3. Verify fix — test passes, no regressions
4. If 3+ fixes failed → STOP, question architecture, discuss with user

## Red Flags — STOP and Return to Phase 1

- "Quick fix for now, investigate later"
- "Just try changing X and see"
- Proposing solutions before tracing data flow
- "One more fix attempt" after 2+ failures
- Each fix reveals new problem in different place
