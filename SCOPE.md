# Nutrition App For AI — Scope

> A standalone, newly-themed nutrition tracker that doubles as an **open backend for agents**.
> You log via the app; your agent **reads and writes** the same data via MCP. Same data, two
> faces — a user-facing app and an agent-facing API. Multi-user product.
> Source app stripped from: `./art-fitness/` (GitHub `arttiongson/art-fitness`).
> Status: scoping complete — stack decided, ready to build. Last updated 2026-05-31.

## Thesis
"Apps for AI." Your nutrition data should not be locked in a silo — it should be openly
exposed (Plaid-style) so your personal agent can coach and analyze. You do the logging
(easy, you know what you ate); the agent does the thinking.

## Locked decisions
| Decision | Choice |
|---|---|
| Source of truth | Cloud backend (not on-device) |
| Stack | **Supabase** (Postgres + auto-REST + auth + RLS) — validated vs Neon, Convex, Firebase |
| Agent access | **Read + write (committed)** — agents are first-class clients of the backend |
| Agent interface | MCP (read + write tools) |
| App role | Client of the backend API (not local-only SwiftData) |
| Billing | **Web/Stripe, not iOS IAP** |
| Photos | **Parse-and-discard** (downscaled) — keep macros, not images |

### Backend decision (LOCKED) — Supabase, validated vs alternatives
Chosen because Postgres **RLS** is best-in-class for the security-critical requirement
("an agent writes ONLY into its own user's rows" — enforced in the DB, not app code), and
it's a full platform (auth + edge functions for `/log` + storage + Swift SDK + pgvector for
agent memory later) on portable Postgres (low lock-in). Beats: Convex (document model, FSL
license, hard migration — wrong for relational multi-tenant data), Firebase (NoSQL, no SQL/RLS),
Neon (pure DB, you'd build auth/RLS/storage yourself — the credible "own everything" runner-up).

**The one gap Supabase does NOT solve — tracked as a build task:**
1. **MCP server is hosted separately** (Fly/Railway), talking to Supabase over Streamable HTTP.
   NOTE: the "Convex MCP server" is a dev tool for coding agents, not a per-user data API — we
   build our own MCP regardless of backend.

**Agent token minting — RESOLVED, not ours to build.** Decision (2026-06-01): **Supabase Auth
acts as the OAuth 2.1 authorization server.** The agent runs OAuth auth-code + PKCE against
Supabase and gets a real user JWT; the MCP server (an OAuth 2.1 *resource server*) validates it
and forwards it to Supabase, so RLS confines the agent automatically. No custom `agent_tokens`
table, no self-minted tokens. MCP spec rev 2025-11-25, SDK `@modelcontextprotocol/sdk@^1.29`.

### Product stance: agents are first-class writers
Any user can hand their own agent a photo (or text) — "log this into my nutrition db" — and
the agent calls `log_meal` with a **user-scoped write token**; the backend parses and writes
the entry **into that user's DB only** (RLS enforces `user_id` ownership). Your service is the
backend; the agent is just another authenticated client. The iOS app and the agent write
through the *same* path. An agent can never write outside its user's scope.

## Architecture
```
   USER ──▶  iOS app  ─┐ writes (log meals)
            (re-themed) │
                        ▼
                 ┌──────────────────────┐
                 │  Supabase backend    │  ← source of truth
                 │  Postgres + REST + RLS│
                 └──────────────────────┘
                        ▲
   AGENT ─▶ MCP server ─┘ reads + writes (coach, analyze, log)
            (user-scoped tokens; RLS-confined)
```

## Data model (port from `art-fitness`)
From `Models/NutritionEntry.swift` (flat, zero fitness coupling):

`nutrition_entries`
- id (uuid, pk)
- logged_at (timestamptz)
- meal_type (enum: breakfast/lunch/dinner/snack)
- description (text)
- calories (int)
- protein_g / carbs_g / fat_g (numeric)
- source (enum: manual / ai / ...)
- ai_confidence (numeric, nullable)
- user_id (uuid) — RLS partition key; every row is owned by a user

`targets` (from `User`/`Goal` + `NutritionTargetService`) — **stored computed** (decision 2026-06-01):
a Postgres trigger recomputes this row on profile/goal change; clients just read it.
- user_id, calories, protein_g, carbs_g, fat_g, effective_from

RLS on every table from day one — multi-tenant; each user (and their agent) sees only their rows.

## API surface
Read (live):
- `GET /day?date=` → entries + totals + targets + tracking status
- `GET /range?start=&end=` → trend data
- `GET /targets`
- `GET /entries?query=` → search

Write (app + agent, both via user-scoped tokens; RLS-confined):
- `POST /entries`
- `PATCH /entries/:id`, `DELETE /entries/:id`
- `PUT /targets`

Derived/AI endpoints (thin custom layer or edge functions — not free CRUD):
- `POST /log` → natural-language or photo → parsed structured entry (the killer UX / core IP).
  Downscales image to ~768px before the model call (see AI meal-parsing below).
- `GET /trends` → computed summaries for the agent

## AI meal-parsing (vision) — LOCKED
Researched May 2026. Parser is decoupled from the agent: the agent is Claude (MCP),
the photo→macros parser is whatever's cheapest/fastest. Source app already abstracts this
(`AIService` protocol + `GeminiAIService` + `ClaudeAIService` + `AIServiceRouter`), so the
provider is a config swap, not a rewrite.

Decisions:
- **Default parser = Gemini 3.1 Flash-Lite** — fastest (~363–381 tok/s vs ~110–140 for
  Haiku), modern, cheap, already wired. (Floor-cost alt: Gemini 2.5 Flash-Lite.)
- **Downscale every image to ~768px in `/log` before the API call** — biggest single cost
  lever (cuts image tokens ~6k→~250–1k, i.e. 3–6×), negligible accuracy loss for food ID.
- **Confidence-gated escalation** — parse on Flash-Lite; if `aiConfidence` is low, escalate
  that one photo to **Gemini 3.5 Flash** (GA — `gemini-3.1-pro` is preview-only, do not ship it).
  Rare → cheap. `AIServiceRouter` is the home for this logic.
- **GPT-4o-mini is banned for vision** — ~33× image-token multiplier; cheap text headline
  is a trap for image-heavy use.
- **Accuracy is a PRODUCT problem, not a model-choice problem.** All VLMs ID food well but
  estimate calories/portions poorly (Nutrition5K: calorie ~0.71 AUCROC across models);
  single-photo depth is the universal limit. Switching providers does NOT fix it. The real
  levers, which we own:
  - multi-angle capture (we allow up to ~6 photos/day → let some be the same meal, multiple angles)
  - correction loop (`source` + `aiConfidence` already support "AI guessed → user fixed";
    corrections double as future fine-tuning data)
  - optional text hint alongside photo ("8oz steak") collapses portion ambiguity
- **Keep the provider abstraction** so the parser stays swappable as models/prices move.

### Parsing cost
Negligible at single-user scale (free tier likely covers it). Downscaling to ~768px cuts image
cost 3–6×. Detailed multi-user cost projections live in private notes (not in this repo).

## MCP tools (read + write, committed)
Read (any valid token):
- `get_nutrition_today()` → totals + entries + targets + how you're tracking
- `get_nutrition_day(date)`
- `get_nutrition_range(start, end)` → trends to reason over
- `get_targets()`
- `search_entries(query)`

Write (user-scoped write token; RLS confines to the user's own rows):
- `log_meal(photo | text, note?, meal_type?)` → backend parses (Gemini) + writes the entry.
  This is the headline flow: "agent, log this photo into my nutrition db."
- `update_entry(id, ...)` / `delete_entry(id)`
- `set_targets(...)`

## iOS app changes
- Strip nutrition into standalone app: `NutritionEntry`, 3 services
  (`NutritionDayService`, `NutritionTargetService`, `MealTypeInference`),
  2 views (`NutritionTabView`, `NutritionEntryModalView`). Zero fitness coupling.
- Replace on-device SwiftData persistence → API client + local cache (keep it feeling instant).
  **This is the real work in the app**, not the re-theme.
- Keep AI meal-parsing — it's the core IP and best UX.
- New theme/identity (name TBD).

## Cost model & monetization
Detailed cost model, pricing, and margins are kept in private notes, out of this public repo.

## Build sequencing
1. **Backend spine** — Supabase project, `nutrition_entries` + `targets` tables, RLS,
   user-scoped read + write tokens.
2. **AI `/log` endpoint** — photo (downscale → Gemini parse) + natural-language → entry.
   Shared by app and agent.
3. **MCP server (read + write)** — wire read tools + `log_meal`. **Hosted separately**
   (Fly/Railway) over Supabase, Streamable HTTP; **Supabase Auth is the OAuth 2.1 AS**, MCP
   server is the resource server (validates the user JWT, forwards to Supabase, RLS confines).
   _Headline proof: "agent, log this photo into my nutrition db" writes a real entry._
   **Sub-phase breakdown for steps 1–3 lives in [BUILD_PLAN.md](BUILD_PLAN.md).**
4. **iOS strip + re-point** — standalone themed app, SwiftData → API client.
5. **Confidence-gated escalation** — low-confidence photos → Gemini 3.5 Flash.
6. **Fitness layer (later)** — same template; harder (relational Workout→Exercise→Set, entangled coach logic).

## Open questions (the only things left before building)
- **App name / theme / identity** — directions drafted (editorial / lab-notebook / brutalist /
  retro), not yet chosen.
- **Human sign-in UX** — passkey vs magic link (Supabase Auth). Agent side is settled:
  user-scoped tokens, not a sign-in flow.

## Resolved
- AI meal-parsing runs **backend-side** (`/log` endpoint) — secures the API key and lets the
  agent reuse the same endpoint. Default model + downscaling + escalation locked above.
- **Backend = Supabase** (validated vs Neon/Convex/Firebase). MCP hosted separately; **agent
  auth = Supabase Auth as OAuth 2.1 AS** (resolved 2026-06-01 — not a custom token mint).
- **MCP runs hosted** (remote, multi-user) — not local Claude Desktop, since any user's agent
  must reach it.
