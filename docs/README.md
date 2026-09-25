# Payday docs

Start with the product and design documents to understand what Payday is. The engineering documents explain how it is built and verified.

## Product and design

- [PRODUCT.md](PRODUCT.md): what the app does and why. The daily loop, the pillars, and what not to build.
- [DESIGN.md](DESIGN.md): how it looks and behaves. Payday shares one design language with its sister app, Vero.

## Engineering

- [PAYDAYCORE_GOAL.md](PAYDAYCORE_GOAL.md): the goal behind PaydayCore, the single earnings engine every number comes from.
- [METRICS.md](METRICS.md): every metric the app computes, where each one is shown, and the contract they follow.
- [PAYDAY_API.md](PAYDAY_API.md): the REST API and MCP endpoint for AI agents.
- [CI.md](CI.md): the five CI jobs and how to run each one locally.
- [SENTRY.md](SENTRY.md): crash reporting, and what is deliberately not collected.

## Releasing

- [RELEASE_GATE.md](RELEASE_GATE.md): the pass/fail gate a release candidate must clear, with recorded evidence.
- [runbooks/](runbooks/): step-by-step procedures for production operations.

## Design notes

[design/](design/) holds the working plans and briefs behind individual changes. They record decisions as they were made, so they can be out of date. The documents above are the current source of truth.
