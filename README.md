# Nutrition App For AI

> An open nutrition tracker that doubles as an **agent-readable backend**. You log meals
> (photo or text); your personal AI agent reads and writes the same data over MCP to coach
> and analyze. Same data, two faces — a user-facing app and an agent-facing API.

*(Working title — final name TBD.)*

## Why
Your nutrition data shouldn't be locked in a silo. This exposes it Plaid-style: you do the
logging (you know what you ate), the agent does the thinking. It's a reference implementation
of a **consumer app built for AI** — Supabase + Postgres RLS + a hosted MCP server + OAuth.

## Architecture
```
USER ──▶ app ──┐ writes
               ▼
        Supabase (Postgres + RLS)  ← single source of truth, every row owned by a user
               ▲
AGENT ─▶ MCP ──┘ reads + writes (OAuth 2.1; RLS-confined to its own user)
```
- **Backend:** Supabase — Postgres, Row-Level Security, Auth (as OAuth 2.1 server), Edge Functions.
- **AI parsing:** a `/log` Edge Function downscales a photo and parses macros (Gemini), server-side.
- **Agent interface:** a hosted MCP server (read + write tools) — Supabase issues the user JWT, RLS does the isolation.

See [SCOPE.md](SCOPE.md) for the full design and [BUILD_PLAN.md](BUILD_PLAN.md) for the phased build.

## Status
Building the backend spine (Phase 1). Not yet usable.

## Setup
1. Create a Supabase project at [supabase.com](https://supabase.com).
2. `cp .env.example .env` and fill in your keys (`.env` is gitignored — never commit secrets).
3. Install the CLI: `brew install supabase/tap/supabase`, then `supabase login`.
4. Link and push the schema: `supabase link --project-ref <ref>` → `supabase db push`.

## License
[MIT](LICENSE).
