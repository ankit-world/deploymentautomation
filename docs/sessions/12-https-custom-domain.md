# Session 12 — HTTPS / Custom Domain

## Goal

Move off the ALB's default HTTP DNS name onto a real domain with HTTPS.

## Prerequisites

- Session 08 done (ALB exists).
- The user has (or has purchased) a domain name.

## Deliverables

- `infra/aws-cli-scripts/11-acm-route53.sh` — ACM certificate (DNS validation) for the domain,
  Route53 hosted zone + validation records, A/ALIAS record pointing the domain at the ALB.
- ALB listener update: add an HTTPS (443) listener using the new cert, redirect HTTP (80) → HTTPS.
- Update frontend/backend CORS and cookie `Secure`/`SameSite` settings now that everything is
  HTTPS.

## Done criteria

- `https://<domain>` serves the app with a valid certificate (no browser warnings); plain HTTP
  requests redirect to HTTPS.
