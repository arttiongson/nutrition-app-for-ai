# Phase 3 — MCP Server (complete scope)

> The "app for AI" payoff: a hosted MCP server that lets a user's agent **read and write**
> their nutrition data, confined to their own rows by the same RLS we proved in Phase 1.
> Companion to [SCOPE.md](SCOPE.md) and [BUILD_PLAN.md](BUILD_PLAN.md). Last updated 2026-06-01.

## Two findings that shaped this scope (researched 2026-06-01)
1. **You cannot pass an image into an MCP tool.** Tool *inputs* are JSON-only (the image
   content type exists only for tool *results*). So the photo flow is: **the agent (Claude)
   parses the photo with its own vision**, then calls `log_meal` with **structured macros**.
   → The MCP server needs **no image handling and no Gemini call.** (Our `/log` Gemini function
   stays — it's for the iOS app's photo path, where no agent is in the loop.)
2. **Supabase ships a native OAuth 2.1 Server** (Public Beta, Nov 2025) with discovery,
   `/authorize`, `/token`, PKCE, dynamic client registration, and JWKS — purpose-built for MCP.
   So the agent does the OAuth dance directly against Supabase; our server just validates the JWT.

## Locked decisions
| Decision | Choice |
|---|---|
| Auth | **Full OAuth** — Supabase OAuth 2.1 Server as the AS; our server is the resource server |
| Tool surface | **Full** — reads + writes + **profile & goals** management |
| `log_meal` input | **Structured** macros (agent already parsed; no image blob) |
| Transport | Streamable HTTP, SDK `@modelcontextprotocol/sdk@^1.29` |
| Hosting | Fly.io / Railway (long-running Node) |
| Server privileges | publishable key + the **caller's JWT** only — no service key, no Gemini key |

## Architecture
```
                         OAuth 2.1 (browser, PKCE, DCR)
   USER's AGENT  ───────────────────────────────────────▶  Supabase Auth (OAuth AS)
   (Claude)                                                 issues user JWT (sub=user, role=authenticated)
       │  Authorization: Bearer <user JWT>  (auto-refreshed by the client)
       ▼
   ┌──────────────────────────┐   forwards the JWT      ┌────────────────────────┐
   │  Our MCP server (RS)      │ ─────────────────────▶ │ Supabase Postgres + RLS │
   │  validates JWT via JWKS   │   PostgREST / RPC       │ confines to sub's rows  │
   │  thin tools over PostgREST│                         └────────────────────────┘
   └──────────────────────────┘
```

## Auth flow (consumer → server → DB)
1. User runs `claude mcp add --transport http nutrition https://<host>/mcp` (or adds it as a
   custom connector on claude.ai).
2. Client hits `/mcp` → server returns **401 + `WWW-Authenticate`** with our Protected Resource
   Metadata URL.
3. Client fetches `/.well-known/oauth-protected-resource` → sees `authorization_servers` =
   the Supabase issuer → discovers Supabase's `/authorize` + `/token` + DCR.
4. Client runs **OAuth 2.1 auth-code + PKCE** (browser consent), self-registers via **DCR**,
   gets a **user JWT** (+ refresh token it rotates).
5. Every tool call arrives with `Authorization: Bearer <user JWT>`. Server **validates it via
   the project JWKS** (`jose`, ES256), reads `sub`, and creates a Supabase client carrying that
   JWT → **RLS confines every query to that user.**

**What you need to use it (your literal question):** the server deployed at a URL; your agent
pointed at it (`claude mcp add …`); a one-time browser login (OAuth); and — for a photo — nothing
extra, Claude's vision parses it and calls `log_meal` with the numbers.

## Tool surface
Units everywhere: **calories = kcal, macros = grams, weight = lb, height = cm, dates = ISO**.
The server ships `instructions` telling the agent to read before coaching, and that photos are
parsed by its own vision then logged as structured macros.

**Read**
| Tool | Returns |
|---|---|
| `get_nutrition_today()` | `nutrition_day` RPC — entries + totals + targets + **remaining**, in the user's tz |
| `get_nutrition_day(date)` | same, for a date |
| `get_nutrition_range(start, end)` | `nutrition_range` RPC — per-day totals + averages |
| `get_targets()` | latest targets row |
| `search_entries(query, start?, end?, limit?)` | entries matching description text |
| `get_profile()` | stats, goals, timezone (context for reasoning) |

**Write**
| Tool | Effect |
|---|---|
| `log_meal(description, calories, protein_g, carbs_g, fat_g, meal_type?, logged_at?)` | insert entry (`source=ai_text`) |
| `update_entry(id, …fields)` | patch an entry |
| `delete_entry(id)` | delete an entry |
| `set_targets(calories?, protein_g?, carbs_g?, fat_g?)` | writes profile **overrides** → trigger recomputes |
| `update_profile(weight_lb?, height_cm?, age?, sex?, training_days_per_week?, timezone?)` | updates stats → trigger recomputes targets |
| `set_goal(type, custom_label?)` | sets the primary goal → trigger recomputes targets |

All writes go through PostgREST under the caller's JWT, so RLS + the `WITH CHECK` policies
enforce ownership (proven in Phase 1).

## DB support (DONE + verified 2026-06-01)
- `profiles.timezone` column added.
- `nutrition_day(date?)` + `nutrition_range(start, end)` RPCs (SECURITY INVOKER, RLS-scoped,
  timezone-aware) — smoke-tested: totals/targets/remaining and per-day series all correct.

## Server config (env)
`SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `SUPABASE_PROJECT_REF` (for the JWKS issuer),
`MCP_PUBLIC_URL` (this server's public URL, for the PRM `resource`), `PORT`. **No service key,
no Gemini key.**

## Sub-phases & status
1. **Pre-req: timezone + read RPCs** — ✅ done, verified.
2. **3.1 Server skeleton** — Node + SDK, Streamable HTTP, PRM + `/health`, deploy to Fly/Railway.
3. **3.2 Auth** — JWKS verify (`jose`), 401 + `WWW-Authenticate`, forward JWT → RLS.
4. **3.3 Read tools** — wired to the RPCs + PostgREST.
5. **3.4 Write tools** — structured `log_meal`, update/delete, set_targets, update_profile, set_goal.
6. **3.5 Server `instructions` + tool docs.**
7. **3.6 ✅ Headline proof** — connect the agent: "I ate a chicken bowl" → row appears;
   "how am I tracking today?" → it reads `get_nutrition_today` and coaches.

## What you (Art) need to set up
- **A host:** a Fly.io or Railway account (free tiers fine) to deploy the Node server + get a URL.
- **Enable Supabase OAuth Server** (Authentication → OAuth Server; toggle on + allow dynamic
  registration). Public Beta.

## Deploy-time-verify (flagged risks)
- **Supabase OAuth Server is Public Beta** — confirm it's enabled and the discovery endpoints
  resolve for the Claude client (there's a known nonstandard well-known path).
- **`aud` is `"authenticated"`, not our URL** — we do NOT strictly bind audience (no custom hook);
  RLS is the boundary. Optionally add a Custom Access Token Hook later for strict RFC 8707.
- **No DB scopes** — all authorization is RLS (which is airtight + proven). Optionally gate agent
  access differently via `auth.jwt() ->> 'client_id'` later.
- **SDK auth surface evolves** — verify the exact transport/auth wiring against the pinned SDK at
  deploy; we use a stateless per-request server + hand-rolled JWKS bearer check to minimize coupling.
