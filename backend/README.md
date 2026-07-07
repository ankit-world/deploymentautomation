# backend

FastAPI + Python 3.12 (tested against 3.11 locally too). Session 01 scope — see
`docs/sessions/01-backend-core.md`: auth (signup/login/refresh/logout) and conversation/message
CRUD against MongoDB Atlas. No LLM calls or file handling yet (session 02).

## Setup

```
cd backend
python -m venv .venv
.venv/Scripts/activate        # Windows; use .venv/bin/activate on macOS/Linux
pip install -r requirements.txt
cp .env.example .env          # then fill in MONGODB_URI and JWT_SECRET
```

## Run

```
uvicorn app.main:app --reload
```

Visit `http://localhost:8000/health` to confirm it's up, and `http://localhost:8000/docs` for the
interactive API docs (Swagger UI).

## Test

```
pytest
```

Tests run against an in-memory MongoDB mock (`mongomock-motor`) — no real Atlas connection or
`.env` file is required to run the test suite.

## API surface (session 01)

- `POST /auth/signup`, `POST /auth/login`, `POST /auth/refresh`, `POST /auth/logout`,
  `GET /auth/me`
- `POST /conversations`, `GET /conversations`, `PATCH /conversations/{id}`,
  `DELETE /conversations/{id}`
- `POST /conversations/{id}/messages`, `GET /conversations/{id}/messages` — the assistant reply
  is a hardcoded placeholder until session 02 wires up OpenAI.
