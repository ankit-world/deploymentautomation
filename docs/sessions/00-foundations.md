# Session 00 — Foundations & Scaffolding

**Status**: done.

## Goal

Lock in the architecture, write the session roadmap, and scaffold an empty monorepo so session 01
has somewhere to start. No framework installs, no business logic, no AWS calls.

## Deliverables

- `docs/ARCHITECTURE.md` — full system design reference.
- `docs/ROADMAP.md` — session checklist + dependency order.
- `docs/sessions/*.md` — this brief, plus one per remaining session.
- `frontend/`, `backend/`, `infra/aws-cli-scripts/`, `infra/docker/` placeholder directories.
- Root `README.md`, `.gitignore`, `.env.example`.
- `git init` (no commit, no remote).

## Done criteria

- `docs/ARCHITECTURE.md` and `docs/ROADMAP.md` exist and describe the full system.
- Repo skeleton matches the layout in `docs/ARCHITECTURE.md`.
- `git status` shows an initialized repo with untracked scaffold files, no commits yet.
