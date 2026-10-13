# Project decisions

This index contains decisions whose rationale remains relevant across multiple changes. Promote a decision here when it constrains future changes, or when the work it governed is reverted or superseded. Change records reference decisions through `links.decisions`; every linked id must exist. Change-specific implementation notes stay with that change.

Each decision is a `DEC-XXXX.md` file:

```markdown
---
protocol_version: "2.0"
id: "DEC-0001"
title: "Short decision name"
status: "active"
date: "YYYY-MM-DD"
supersedes: []
---

## Context

What situation forced the decision, and what evidence was measured.

## Decision

What was chosen, and what was rejected.

## Consequences

What follows, what would reopen the decision, and the cost if it is wrong.
```

`status` is `active`, `superseded`, or `reverted`. `supersedes` optionally lists the decision ids this one replaces.
