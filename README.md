# ChatGPT-style App

A multi-user, ChatGPT-like web app: Next.js/TypeScript/Tailwind frontend, FastAPI backend,
MongoDB Atlas storage, OpenAI-powered chat with image/PDF/Word/Excel attachments, deployed on
AWS ECS Fargate behind an ALB, with Redis (ElastiCache), CloudWatch, self-hosted Grafana, and
GitHub Actions CI/CD.

## Status

Early scaffolding. See `docs/ROADMAP.md` for what's built and what's next.

## Project structure

```
/frontend     Next.js 14, TypeScript, Tailwind CSS
/backend      FastAPI, Python 3.12
/infra        AWS CLI provisioning scripts + Dockerfiles/compose
/docs         Architecture reference and per-session build briefs
```

## Where to start

- `docs/ARCHITECTURE.md` — full system design.
- `docs/ROADMAP.md` — the session-by-session build plan and current progress.
- `docs/sessions/` — one brief per session; each is self-contained enough to hand to a fresh
  Claude Code session.

## Local development

Not yet available — local Docker orchestration lands in session 05. Until then, run the frontend
and backend directly once they exist (sessions 01-04); see each session's brief for specifics.

## Secrets

Copy `.env.example` to `.env` and fill in real values. Never commit `.env`.
