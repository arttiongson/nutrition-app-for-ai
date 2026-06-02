# Build Plan — Phases 1–3 (backend + agent spine)

> Detailed sub-phase breakdown for the Xcode-free half of the project: Supabase backend,
> AI `/log` endpoint, and the hosted MCP server. Companion to [SCOPE.md](SCOPE.md).
> Status: **Phase 1 COMPLETE** (schema + RLS + targets, isolation proven). **Phase 2 COMPLETE** —
> `/log` Edge Function deployed; text + photo proven end-to-end; **2.5 escalation** done (conf < 0.6
> → retry-with-backoff → `gemini-3.5-flash`, synchronous with graceful fallback; mechanism proven via
> `X-Parser-Model` header flip). **Phase 3 (MCP server) next.** Last updated 2026-06-01.
>
> Known caveat: on the **free Gemini tier**, `gemini-3.5-flash` is often capacity-limited (503), so
> escalation currently falls back to flash-lite gracefully — it'll engage reliably on a paid key.
>
> **Phase 3 — server DEPLOYED + PROVEN (2026-06-01):** live at `https://nutrition-mcp-for-ai.fly.dev`
> (Fly, sjc, 2 machines). All 12 tools driven end-to-end through a real MCP client (connect → list →
> read → log_meal → read-back), RLS-confined. DB foundation done (`profiles.timezone`,
> `nutrition_day`/`nutrition_range` RPCs). **Remaining: agent login.** Finding: Supabase's OAuth
> Server requires a **custom consent web page** (Site URL + `authorization_path`; Supabase hosts no
> default UI). **RESOLVED — built the consent page** (`mcp-server/public/consent.html` at `/oauth/consent`).
> Supabase OAuth Server enabled (discovery + DCR + token endpoints live), Site URL set, consent page
> deployed + verified, connector registered in user config (`nutrition`). **Phase 3 effectively COMPLETE** —
> only Art's one-time browser login + live demo remain (interactive). Caveat: `mailer_autoconfirm=true`
> set for frictionless signup — re-enable email confirmation before public. Full scope: `PHASE_3_MCP.md`.
> **None of Phases 1–3 require Xcode** — all Supabase (SQL + Deno) and Node. Xcode is Phase 4 only.

## Locked decisions (this round)
| Decision | Choice | Consequence |
|---|---|---|
| Agent credential | **Supabase Auth = OAuth 2.1 authorization server** | Agent runs OAuth auth-code + PKCE against Supabase, gets a real user JWT. MCP server validates it and forwards to Supabase; RLS confines. **No custom `agent_tokens` table, no self-minted JWTs.** |
| Nutrition targets | **Stored computed targets** | A Postgres trigger recomputes the `targets` row whenever a profile/goal changes; clients just read it. History via `effective_from`. |
| Parsing location | **Single path: `/log` Edge Function** | Both the iOS app and the MCP `log_meal` tool call `/log`. Gemini key never leaves Supabase. |
| Reads | **PostgREST + RPC** | Simple CRUD via auto-REST; composite reads (today = totals+targets+entries) via Postgres RPC functions. |

## Corrections folded in from research (2026-06-01)
1. **Gemini escalation model**: `gemini-3.1-pro` is **not GA** (preview only). Escalation tier = **`gemini-3.5-flash`** (GA). Default stays **`gemini-3.1-flash-lite`** (GA, $0.25/$1.50 per 1M, ~$0.0006/photo). Downscale 512–768px confirmed.
2. **Supabase migration window**: use the **new key model** (`sb_publishable_`/`sb_secret_`, no `anon`/`service_role`) and **asymmetric JWT signing keys (ES256)** — defaults for new projects. Verify the `late-2026` legacy-key deletion date against live docs when building.
3. **MCP standardized** (spec rev **2025-11-25**): server is an **OAuth 2.1 resource server** on **Streamable HTTP** (not SSE); SDK `@modelcontextprotocol/sdk@^1.29`; host on **Fly.io/Railway** (long-running Node).
4. **Gemini structured output**: prefer `generationConfig.responseFormat.text.{mimeType, schema}` (the older `responseMimeType`+`responseSchema` still works).

---

## Phase 1 — Backend spine (Supabase)
**Goal:** schema + RLS proven; a user can only ever see their own rows.

- **1.1 Project & local dev**
  - Create Supabase project; pick a **region co-located with the MCP host** (e.g. both us-west).
  - Confirm new key model (`sb_publishable_` for clients, `sb_secret_` server-only) and ES256 signing keys are active. No custom signing key needed — Supabase signs its own user tokens (we use Supabase-as-AS).
  - Install Supabase CLI; `supabase init`; link project; `supabase start` for local Postgres; migrations under `supabase/migrations/`.
- **1.2 Schema & enums** (port from `art-fitness` models — all confirmed flat, zero fitness coupling)
  - Enums: `meal_type` (breakfast/lunch/dinner/snack), `nutrition_source` (manual/ai_text/ai_photo).
  - `profiles` (→ `auth.users.id` pk): name, height_cm, weight_lb, age, sex, training_days_per_week, dietary_preference, tdee_override, protein_g_override, carbs_g_override, fat_g_override, created_at.
  - `goals`: id, profile_id (→profiles), type, custom_label, priority.
  - `nutrition_entries`: id, user_id (→auth.users), logged_at, meal_type, description, calories (int), protein_g/carbs_g/fat_g (numeric), source, ai_confidence (numeric, nullable), created_at.
  - `targets`: id, user_id, calories, protein_g, carbs_g, fat_g, effective_from, created_at.
  - Indexes: btree on `user_id` (nutrition_entries, targets), `profile_id` (goals).
  - Signup trigger: on `auth.users` insert → create `profiles` row.
- **1.3 RLS** — enable on all four tables. Per-operation policies, `TO authenticated`, `(select auth.uid()) = user_id` (`= id` for profiles). SELECT=USING; INSERT=WITH CHECK; UPDATE=both; DELETE=USING.
- **1.4 Targets computation** (the "store computed" decision)
  - Port the Mifflin-St Jeor → activity factor → goal adjustment → macro split → per-field override logic (currently in `NutritionTargetService.swift`) to a **plpgsql function**.
  - Trigger on `profiles` + `goals` AFTER INSERT/UPDATE → insert a new `targets` row with fresh `effective_from`. Reads take the latest.
- **1.5 Auth + ✅ proof**
  - Enable Supabase Auth (provider choice — magic link vs passkey — deferred; doesn't block).
  - **Proof:** users A & B; insert entries as A; confirm B is denied A's rows; confirm `targets` auto-populates/updates when A's profile changes.

## Phase 2 — AI `/log` endpoint (Supabase Edge Function)
**Goal:** photo or text → parsed macro entry, written under RLS. Shared by app + agent.

- **2.1 Skeleton** — Deno function, `verify_jwt` on, `auth:'user'` scoped client (`ctx.supabase`), `GEMINI_API_KEY` as a Supabase secret.
- **2.2 Image pipeline** — accept photo (multipart/base64) + optional text + meal_type; **downscale longest side to 512–768px, JPEG q≈80**; keep request <20MB; inline base64.
- **2.3 Gemini call** — REST `generateContent` → `gemini-3.1-flash-lite`, `responseFormat` JSON schema (port `AIParsedNutrition`: description, calories, protein_g, carbs_g, fat_g, meal_type, confidence), `thinkingLevel: low`, image part **before** text. Port the portion-size/confidence prompt from `ClaudePromptBuilder.swift`.
- **2.4 Write** — insert via RLS-scoped client (user_id = auth.uid()), set `source` + `ai_confidence`; return the row. Text-only path (no image) supported.
- **2.5 Confidence-gated escalation** — if `confidence < ~0.6`, re-run on `gemini-3.5-flash`. **Recommend async** (return Flash-Lite immediately, patch the entry when escalation lands) to keep p99 low; sync alternative needs a hard timeout.
- **2.6 ✅ proof** — POST a food photo as a user → a correctly-scoped row appears with macros + confidence.

## Phase 3 — MCP server (read + write, hosted)
**Goal:** the headline — "agent, log this photo into my nutrition db" writes a real, user-scoped row.

- **3.1 Skeleton** — Node + `@modelcontextprotocol/sdk@^1.29`, **Streamable HTTP** transport, deploy to **Fly.io/Railway** (region near Supabase), health check.
- **3.2 Auth (Supabase-as-AS)** — serve Protected Resource Metadata at `.well-known/oauth-protected-resource` with `authorization_servers` → the Supabase project's auth endpoint. `requireBearerAuth` validates the Supabase JWT (JWKS), checks scopes; read user from `sub`. ⚠️ Verify exact audience handling against Supabase's MCP-authentication docs (fast-moving surface).
- **3.3 Read tools** — `get_nutrition_today`, `get_nutrition_day(date)`, `get_nutrition_range(start,end)`, `get_targets`, `search_entries(query)` → Supabase PostgREST + an RPC for the `today` composite, **forwarding the user's bearer JWT** so RLS confines.
- **3.4 Write tools** — `log_meal(photo|text, note?, meal_type?)` → calls the `/log` Edge Function with the user JWT; `update_entry`, `delete_entry`, `set_targets` (writes overrides → trigger recomputes).
- **3.5 Agent OAuth flow** — agent's MCP client runs auth-code + PKCE against Supabase; holds the **refresh token**, rotating short-lived (~1h) access tokens. Decide client registration (pre-registered first-party client vs DCR). No custom token store.
- **3.6 ✅ headline proof** — agent logs a photo → row appears scoped to the user, visible in both the read tools and (later) the app.

---

## Dependencies & what's achievable today
`Phase 1 → Phase 2 → Phase 3` (strict). Phase 2 needs Phase 1's schema+RLS; Phase 3's `log_meal` calls Phase 2's `/log`. **Today (remote, no Xcode): all of Phase 1 and most of Phase 2 are realistic.**

## Assumptions baked in (flag if wrong)
- Parsing lives **only** in `/log`; MCP `log_meal` calls it (Gemini key stays in Supabase).
- Composite reads use Postgres RPC functions; plain CRUD uses PostgREST.
- MCP host and Supabase are **region co-located**.

## Verify-live before coding (fast-moving surfaces)
- Supabase MCP-authentication audience/discovery specifics.
- `withSupabase({ auth })` / Edge Function `ctx` API surface.
- Legacy `anon`/`service_role` key deletion date.
- Gemini model IDs + pricing still current.

## v2 — post-validation (needs real logged data, don't build yet)
- **Adaptive TDEE** — the high-value destination, and the clearest "app for AI" differentiator.
  Instead of *predicting* maintenance from Mifflin (a population estimate that's individually off
  by hundreds of cal — see the hand-tuned 1.6 activity factor in `NutritionTargetService`),
  *measure* it from logged data: `real maintenance ≈ avg intake + (Δweight_lb × 3500 / days)` over
  a rolling window. Self-correcting, personal. Perfect agent job ("agent reads your intake + weight
  trend, recalculates your true targets weekly"). **Prereqs:** weeks of logged intake + a new
  **bodyweight log table**; recompute model shifts from trigger-on-edit → rolling/scheduled (cron or
  compute-on-read over a window). v1 Mifflin stays as the day-1 cold start. Build once data exists.

## Deferred (not blocking 1–3)
- Human sign-in UX: passkey vs magic link (Phase 4-ish).
- App name / theme / identity (Phase 4).
- iOS strip & re-point = Phase 4 (needs Xcode + `brew install xcodegen`).
