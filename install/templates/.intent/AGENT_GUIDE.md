# Intent workflow

Follow [protocol/v1.md](protocol/v1.md). Use the lightest workflow that can deliver and verify the requested outcome: understand context, make and record material decisions, implement, verify, and include operations only when requested.

Proceed autonomously when the outcome is clear and within repository policy. Use repository conventions for routine choices; record material assumptions. Ask a human only when unresolved information would materially change the outcome or when repository policy reserves an action for human authority. Keep the question specific and continue independent safe work.

Preserve existing behavior: do not modify, skip, or delete a pre-existing test to make it pass. Declare intended test changes and behavior exceptions in the proposal before implementing, and record conformance in `conformance.md` before the change is marked complete.

## Complete

The change record states the requested outcome, scope, material decisions, and relevant verification. Keep routine changes concise; add detail only when complexity, risk, ambiguity, or repository policy needs it.

Verify the changed behavior with relevant repository checks. Record actual outcomes, material deviations, and results. Human approval evidence and digests are required only when repository policy requires approval.

The installer supplies guidance and records, not a filesystem security boundary. Technical enforcement requires a controller to mediate tool access.

For a repository-wide approval gate, set `review.required: true` and list authorized reviewers in `.intent/config.yaml`. Otherwise, keep the default autonomous flow.
