# Engineering Principles

Standing directive for all work in this repository, from the project owner. These are operating
principles, not general advice. `AGENTS.md` carries the operational core; this file is the full
text and the authority when the two differ.

## Core Principle

Build the simplest correct solution that satisfies the actual objective.

Do not preserve assumptions, abstractions, processes, or code merely because they already exist.
Every requirement and implementation choice must earn its place.

## 1. Define the Objective

Identify the actual outcome the user wants before changing code: what problem must be solved,
what behavior must change, what must remain unchanged, what constraints are real, and how
success will be verified.

Do not confuse the requested implementation with the underlying objective. A user may propose a
solution that is broader, riskier, or more complicated than necessary. Preserve the objective
while selecting the safest and simplest effective implementation.

When the objective is unclear, infer it from context and make the narrowest reasonable
assumption. Do not invent requirements.

## 2. Inspect Before Acting

Understand the relevant system before modifying it: affected files and modules, existing tests,
related interfaces and call sites, project conventions, configuration and dependency boundaries,
error-handling patterns, and nearby implementations of similar behavior.

Do not rewrite code based on assumptions about how the system probably works. Trace the actual
execution path. Read narrowly but sufficiently.

## 3. Challenge Every Requirement

Treat each requirement as provisional until supported by the stated objective, existing behavior
that must be preserved, a test or specification, an external contract, a security, legal,
compatibility or operational constraint, or a clear architectural dependency.

Ask of every requirement: is it necessary, is it a true constraint or a convention, is it still
current, does it apply here, and what breaks if it is removed?

Do not blindly follow comments, tickets, legacy patterns, or prior implementations. Verify them
against the current code and desired behavior.

## 4. Eliminate Unnecessary Work

Before adding code, determine whether the problem can be solved by removing or reusing
something. Prefer, in order: remove an unnecessary requirement, delete obsolete code, use an
existing function or abstraction, correct a small defect, extend an existing pattern, add new
code, add a new abstraction or dependency.

Do not add duplicate utilities, speculative configuration, premature abstractions, unused
flexibility, compatibility layers without demonstrated need, new dependencies for trivial
functionality, fallback behavior that hides defects, or comments that restate the code.

## 5. Simplify the Solution

Prefer direct control flow, explicit data transformations, small focused functions, clear names,
narrow interfaces, local reasoning, predictable failure modes, and established project patterns.

Avoid cleverness, excessive indirection, deep nesting, generic frameworks for one use case,
abstractions that obscure behavior, and broad refactors where a targeted change suffices.

A solution is not simpler merely because it uses fewer lines. Simplicity means another engineer
can understand its purpose, behavior, and failure modes with minimal effort.

## 6. Make the Smallest Correct Change

Limit the modification to the scope required to solve the problem completely. Preserve unrelated
behavior, public interfaces, formatting and style conventions, adequate existing architecture,
and backward compatibility where required.

Do not use a narrow request as an excuse to clean up the surrounding codebase. A broader
refactor is appropriate only when the current structure prevents a correct, safe, or
maintainable solution, and then only as far as necessary.

## 7. Establish Correctness Before Optimization

Make the solution correct, clear, and verifiable first. Only then consider performance, memory,
latency, concurrency, caching, batching, parallelism, code generation, or automation.

Do not optimize hypothetical bottlenecks. Optimization requires evidence: profiling, benchmarks,
production metrics, known scale constraints, or documented requirements. Never make code harder
to understand for an unmeasured benefit.

## 8. Verify With Reality

Do not rely solely on reasoning. Test actual behavior with the strongest practical verification
available: existing tests, new targeted tests, type checking, static analysis, linting, build
validation, focused runtime checks, reproducible manual testing, and benchmarks where
performance is relevant.

Test both the intended success path and meaningful failure or edge cases. When fixing a defect,
add or update a test that would have failed before the fix whenever practical.

Do not claim success when verification has not been performed. State clearly what was tested and
what remains unverified.

## 9. Increase the Rate of Learning

Structure work so incorrect assumptions surface early: small edits, focused tests, short
feedback loops, reversible changes, incremental validation, isolated experiments before large
integrations.

When uncertain, test the uncertainty directly rather than building around it. Do not make
several speculative changes at once. Change one meaningful variable, observe, and proceed on
evidence.

## 10. Handle Errors Explicitly

Do not silently swallow exceptions, return ambiguous sentinels, conceal invalid states with
fallbacks, retry indefinitely, convert programmer errors into apparent success, or log sensitive
information.

Error handling should preserve useful context, fail at the appropriate boundary, distinguish
expected from unexpected failures, avoid exposing secrets or internals, and make recovery
explicit. A fallback is appropriate only when degraded behavior is intentional, safe, and
observable.

## 11. Protect Security and Data Integrity

Treat security, privacy, and data correctness as core requirements. Consider input validation,
authorization, authentication boundaries, injection, unsafe deserialization, path traversal,
race conditions, secret exposure, logging of sensitive data, destructive operations,
transactional consistency, partial failure, idempotency, and rollback.

Use least privilege and secure defaults. Never weaken a security control to make a test pass or
simplify an implementation.

## 12. Respect Existing Contracts

Identify and preserve function signatures, API schemas, command-line behavior, database
constraints, serialization formats, environment variables, configuration keys, file formats,
event payloads, user-visible output, and error semantics.

When a contract must change, update all affected consumers, tests, and documentation. Do not
introduce accidental breaking changes.

## 13. Avoid Speculative Generalization

Solve the demonstrated problem, not every imaginable future problem. Do not add extension
points, plug-in systems, strategy layers, or generic configuration without concrete present
requirements.

Use the rule of three cautiously. Repetition alone does not justify abstraction; abstract only
when the shared concept is stable and the abstraction makes the code easier to understand.
Duplication is sometimes cheaper than the wrong abstraction.

## 14. Automate Only Proven Processes

Before automating, confirm the behavior is correct, inputs and outputs are stable, failure modes
are known, the process is worth repeating, and automation will not conceal judgment that still
requires human review. Do not automate a broken, unclear, or unnecessary process.

## 15. Document Decisions, Not Syntax

Code explains what it does. Comments and documentation explain why the behavior exists, why a
non-obvious approach was chosen, what constraint prevents a simpler solution, what invariant
must be preserved, what external contract is honored, and what risk future maintainers should
understand.

Do not write comments that paraphrase obvious code. Update documentation when behavior,
configuration, usage, or public contracts change.

## 16. Leave the System Better, but Not Broader

Within the affected area: remove dead code the change made obsolete, correct misleading names or
comments related to the work, simplify logic you touched, and keep tests and documentation
aligned.

Do not expand into unrelated cleanup. The goal is a cleaner path through the code you had to
touch, not an unsolicited repository-wide renovation.

## 17. Report Results Precisely

Communicate what changed, why, where, how it was verified, and any limitations, risks, or
unresolved issues.

Do not exaggerate certainty. Distinguish verified behavior from reasoned conclusions, from
assumptions, from untested areas. Do not bury failures or incomplete verification.

## Decision Sequence

1. Define the actual objective.
2. Inspect the relevant system.
3. Question every assumption and requirement.
4. Delete unnecessary work, code, and complexity.
5. Reuse existing capabilities where appropriate.
6. Simplify the remaining design.
7. Implement the smallest correct change.
8. Verify behavior through tests and tools.
9. Optimize only when supported by evidence.
10. Document meaningful decisions.
11. Report results and limitations accurately.

The order matters. Do not optimize before simplifying. Do not automate before validating. Do not
abstract before understanding. Do not modify before inspecting. Do not claim success before
verifying.

## Default Coding Standards

Unless the repository establishes a different convention: prefer readability over cleverness;
explicit behavior over hidden magic; composition over inheritance; pure functions where
practical. Keep side effects near system boundaries. Validate external input. Make invalid
states difficult to represent. Use descriptive names. Keep functions focused. Avoid mutable
global state and unnecessary dependencies. Preserve deterministic behavior. Add tests for
changed behavior. Treat warnings and failing checks as signals, not obstacles. Never disable
safeguards without understanding and documenting the reason.

## Final Standard

A successful change is not merely code that runs. It must be **correct** (produces the required
behavior), **necessary** (each material part serves the objective), **simple** (no avoidable
complexity), **scoped** (changes no more than required), **safe** (protects data, security, and
existing contracts), **tested** (behavior meaningfully verified), **maintainable** (another
engineer can understand and modify it), and **honest** (limitations and verification status
clearly stated).

The job is not the most code, the most sophisticated architecture, or the fastest apparent
result. It is the simplest verified solution to the real problem.
