# Spike N: title

YYYY-MM-DD · author · status: planned | running | done

> One or two sentences: what was asked and what the answer is. Write this last. A reader who stops here should know the decision.

## Question

The question from the implementation plan, word for word, then any sharpening done before starting. List the architecture hypotheses **(H, spike n)** this spike is meant to settle.

## Decision rule

Written **before** collecting data. What result means go, what means no-go, and what means a narrower scope. For sample-based claims, state the sample rule (for example the D3 rule: a one-sided 95% Clopper–Pearson bound on the failure rate at or below 0.5%, which takes 598 clean attempts, about 948 with one failure, about 1,258 with two).

## Method

What was built and how it was run, in enough detail to repeat it. Name the tool under `Tools/spikes/` and the exact command lines. Say what the tool can and cannot observe, and what served as ground truth.

## Environment

| Item | Value |
| --- | --- |
| Hardware | |
| macOS version and build | |
| Xcode and Swift | |
| Apps under test, with versions | |
| Permissions granted | |
| Jilpa commit | |

## Results

Tables with counts, never bare percentages. One row per app, variant and OS where the question is per cell. Report unknowns and failures as their own rows instead of folding them into a rate.

| App | Version | Variant | OS | Attempts | Pass | Fail | Unknown | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |

Latency where it matters: p50, p95, max, with the sample count.

### Surprises

Anything that contradicts the architecture doc or that a later spike should know.

## Decision

Go, no-go or narrowed scope, measured against the decision rule above. If a threshold was missed, say so plainly and say what follows.

## Architecture impact

For each hypothesis this spike touched: **confirmed**, **replaced** (with what) or **removed**. List the edits owed to `docs/ARCHITECTURE.md`, `docs/PRD.md` and `docs/COMPATIBILITY.md`, and any change to a later spike or work package.

| Hypothesis or section | Outcome | Edit owed |
| --- | --- | --- |

## What is kept

Code or data that survives the spike (for example additions to `JilpaAX`, FixtureApp variants, signature tables, soak drivers). Everything else under `Tools/spikes/` is throwaway.

## Raw data

Where it lives and what it contains. Raw data that can hold paths, filenames, window titles or URLs stays out of git. Spike 0 data holds counts only.
