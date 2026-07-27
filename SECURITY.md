# Security policy

Eddie's Wallet is an unfinished, unreleased frontend MVP. Even so, it is a family product concept that involves a child's profile, so security and privacy reports are taken seriously and handled privately.

## Supported versions

There are no released, tagged, or distributed builds of Eddie's Wallet, so there are no supported release versions. Security fixes land only on the `main` branch of this repository. If you build the app yourself, rebuild from the latest `main` to pick up fixes.

## Reporting a vulnerability

Report vulnerabilities privately through GitHub's private vulnerability reporting for this repository:

**<https://github.com/kunchenguid/eddies-wallet/security/advisories/new>**

**Do not open a public issue, discussion, or pull request for a security or privacy finding.** This applies with extra force to anything involving a child's or family's data, sign-in, or the parent/child permission boundary: never post such findings, reproduction data, or screenshots publicly.

When reporting, please include what you can of: the affected file or flow, reproduction steps, the impact you believe is possible, and any suggested fix. Synthetic data only, please; do not include real family, account, or credential material in a report.

What to expect: this is a solo, best-effort project with no bug bounty. You should receive an acknowledgment within a few days, and validated reports will be fixed on `main` and credited in the advisory if you wish.

## Scope

This repository contains only the native client. Reports about the separately operated backing service may be sent through the same private route; they reach the same owner and will be handled with the service operator. Please do not probe the production service beyond what is needed to demonstrate a finding, and never test against real families or attempt to access data that is not yours.
