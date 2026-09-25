# JaryneticsUtility Agent Instructions

## Purpose

This repository contains Jarynetics Utility Bill Intelligence, governed by
UPR-001 Version 0.1 and the approved Jarynetics product lifecycle decisions.

Codex is an implementation agent. Product scope, architecture, governance,
acceptance, release authority, and controlled source decisions remain with the
CEO and Atlas review process.

## Development Principles

- Work only within the explicitly authorized task.
- Prefer the smallest reversible implementation that satisfies the requirement.
- Do not silently expand scope.
- Do not introduce speculative architecture for anticipated future needs.
- Preserve local-first and document-first product behavior.
- Core product behavior must not require paid cloud OCR, paid external LLMs,
  utility-data aggregators, automatic provider connectivity, or a Jarynetics
  bill-processing backend unless separately authorized.
- Deterministic verified data is the product truth layer.
- Generative AI must not establish authoritative bill facts, arithmetic,
  entitlement state, deletion behavior, or causal explanations.
- Customer-visible extracted information must remain correctable and source
  traceable.

## Privacy and Test Data

- Never use real customer utility bills as development fixtures.
- Use synthetic, public sample, or appropriately redacted documents.
- Do not add secrets, credentials, API keys, payment information, utility
  passwords, personal account numbers, or production tokens to the repository.
- Do not transmit bill contents or household data to external services unless
  separately authorized.
- Avoid diagnostic logging of bill contents or sensitive normalized values.

## Source Control

- Do not commit, push, merge, rebase, reset, force-push, or delete branches
  unless the task explicitly authorizes that action.
- Do not modify accepted Git history.
- The CEO performs final commit and push actions.
- Do not work directly around a dirty or unexplained repository state.
- Report unexpected existing changes before proceeding.

## Dependencies and Platform Changes

Do not add or materially modify any of the following without explicit approval:

- third-party packages or SDKs;
- network services;
- CloudKit or external synchronization;
- analytics or telemetry services;
- external OCR or AI services;
- utility-provider APIs or Green Button integrations;
- account or credential storage;
- signing identities or provisioning;
- App Store Connect configuration;
- StoreKit production configuration;
- privacy entitlements;
- backend infrastructure.

If the authorized task appears to require one of these, stop and report the need.

## Engineering Quality

- Preserve existing architecture unless the task requires a justified change.
- Add or update tests for material product behavior.
- Run relevant tests after implementation.
- Run the full practical test suite before declaring a bounded task complete.
- Treat build success alone as insufficient evidence of correctness.
- Surface partial recognition, persistence failures, unsupported formats, and
  other recoverable failures explicitly rather than silently discarding data.
- Prefer readable Swift and straightforward product logic over unnecessary
  abstraction.

## Permission and Internet Boundary

- Internet access is not assumed.
- Do not attempt to bypass Xcode or agent permission controls.
- If an unapproved command, filesystem location, web request, or tool is needed,
  request permission and explain why.
- Do not work around a denied permission.

## Mandatory Completion Handoff

At the end of every implementation task, provide the complete handoff below. Do not end the task after Build/Test completion. Before considering the task complete, you MUST emit the full Mandatory Completion Handoff in the conversation. A task is incomplete until that handoff has been provided:

1. Objective completed.
2. Files created.
3. Files modified.
4. Customer-visible behavior added or changed.
5. Architecture or data-model decisions introduced.
6. Tests added or modified.
7. Build result.
8. Test result, including test counts when available.
9. Commands or permissions requested outside the standing allowed set.
10. Unresolved issues, assumptions, warnings, or deviations.
11. `git diff --stat` summary.
12. Confirmation that no commit, push, merge, destructive Git action,
    unapproved dependency, external service, or internet access occurred.

If the task cannot be completed within its approved scope, stop and explain the
blocking issue rather than broadening scope.

## Acceptance

Codex completion does not constitute Jarynetics acceptance.

Work becomes the controlled baseline only after CEO review, Atlas review when
applicable, required Build/Test verification, and the CEO-controlled Git
commit/push process.
