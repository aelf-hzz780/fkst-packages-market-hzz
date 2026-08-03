# Security Policy

## Supported scope

Security reports for this repository should cover:

- the business-owned FKST Market packages;
- the minimal local FKST Lua support libraries kept for those packages;
- repository scripts and CI configuration;
- documentation that affects runtime operation.

Generic FKST host/runtime behavior belongs in `fkst-hosted`. FKST engine, sandbox, durable delivery, SDK primitive, or Rust implementation issues belong in `fkst-substrate`.

## Reporting a vulnerability

Use GitHub private vulnerability reporting for this repository when available. If private vulnerability reporting is unavailable, open a minimal public issue asking the maintainers for a private reporting channel.

Do not include exploit details, secrets, tokens, private logs, or proof-of-concept payloads in public issues.

Include enough information for maintainers to reproduce and assess the issue privately:

- affected package, script, workflow, or document;
- the security impact;
- reproduction steps or a minimal proof of concept;
- whether GitHub write posture, X publishing, Telegram governance, NyxID, credentials, or external command execution is involved;
- any known mitigations.

## Credential posture

No raw credentials belong in this repository, manifests, tests, or GitHub issue payloads.

User-owned service credentials must be supplied through FKST Environment Profiles / NyxID at runtime. Live X and Telegram writes must fail closed unless the user-owned environment explicitly enables the relevant write gates and preflight succeeds. Telegram API keys must remain in NyxID; R2 commands must use an independent destructive credential and two-person GitHub approval.

⟦AI:FKST⟧
