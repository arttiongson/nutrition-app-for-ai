// Nutrition MCP server — OAuth 2.1 resource server over Supabase.
// Every tool runs under the CALLER's Supabase JWT, so RLS confines it to that user's rows.
// Stateless per-request: validate the bearer, build a server bound to that JWT, handle, close.
// NOTE: a few SDK/Supabase surfaces are fast-moving (see ../PHASE_3_MCP.md "deploy-time-verify").

import express, { type Request, type Response } from "express";
import { createRemoteJWKSet, jwtVerify } from "jose";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";
import path from "node:path";
import helmet from "helmet";
import rateLimit from "express-rate-limit";

function reqEnv(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing env ${name}`);
  return v;
}

const SUPABASE_URL = reqEnv("SUPABASE_URL");
const SUPABASE_PUBLISHABLE_KEY = reqEnv("SUPABASE_PUBLISHABLE_KEY");
const PROJECT_REF = reqEnv("SUPABASE_PROJECT_REF");
const MCP_PUBLIC_URL = process.env.MCP_PUBLIC_URL ?? "http://localhost:3000";
const PORT = Number(process.env.PORT ?? 3000);

const ISSUER = `https://${PROJECT_REF}.supabase.co/auth/v1`;
const MCP_RESOURCE = `${MCP_PUBLIC_URL}/mcp`;   // RFC 8707: tokens must carry this in `aud`
const JWKS = createRemoteJWKSet(new URL(`${ISSUER}/.well-known/jwks.json`));

// Validate a Supabase access token locally against the project JWKS, return the user id (sub).
// `aud` carries our resource URL (stamped by a Supabase access-token hook), so we bind audience
// per RFC 8707 — a token minted for another resource is rejected. RLS remains the real boundary.
async function verify(token: string): Promise<string> {
  // Pin ES256 (alg-confusion defense) + require our resource URL in `aud` (RFC 8707).
  const { payload } = await jwtVerify(token, JWKS, { issuer: ISSUER, algorithms: ["ES256"], audience: MCP_RESOURCE });
  if (!payload.sub) throw new Error("token has no sub");
  // Only end-user tokens — reject service_role/anon tokens, which would bypass or break RLS.
  if (payload.role !== "authenticated") throw new Error("unexpected role");
  return payload.sub;
}

function userClient(jwt: string): SupabaseClient {
  return createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
    global: { headers: { Authorization: `Bearer ${jwt}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

const MEAL = z.enum(["breakfast", "lunch", "dinner", "snack"]);
const SEX = z.enum(["male", "female", "prefer_not_to_say"]);
const GOAL = z.enum(["fat_loss", "muscle_gain", "strength", "general_health", "custom"]);
// Bounded input primitives (defense-in-depth; the DB also CHECK-constrains these).
const CAL = z.number().int().min(0).max(20000);
const GRAMS = z.number().min(0).max(5000);
const DESC = z.string().min(1).max(500);
const DATE = z.string().max(40);

const ok = (data: unknown) => ({ content: [{ type: "text" as const, text: JSON.stringify(data, null, 2) }] });
const fail = (msg: string) => ({ content: [{ type: "text" as const, text: msg }], isError: true });
const wrap = (r: { data: unknown; error: { message: string } | null }) => (r.error ? fail(r.error.message) : ok(r.data));

function inferMeal(d: Date): "breakfast" | "lunch" | "dinner" | "snack" {
  const h = d.getHours();
  if (h >= 4 && h < 11) return "breakfast";
  if (h >= 11 && h < 15) return "lunch";
  if (h >= 17 && h < 21) return "dinner";
  return "snack";
}

const INSTRUCTIONS = `Nutrition data for the signed-in user.
Units: calories=kcal, macros=grams, weight=lb, height=cm, dates=ISO 8601.
Before coaching, READ first — get_nutrition_today returns totals, targets, and remaining (no math needed).
To log a meal from a PHOTO: analyze the image yourself, then call log_meal with structured macros (you cannot pass an image to a tool).
All data is confined to this user by the database; you can only ever see or modify their own rows.`;

function buildServer(jwt: string, userId: string): McpServer {
  const db = userClient(jwt);
  const server = new McpServer({ name: "nutrition", version: "0.1.0" }, { instructions: INSTRUCTIONS });

  // ── reads ──────────────────────────────────────────────────────────────
  server.registerTool("get_nutrition_today",
    { description: "Today's entries, totals, targets, and remaining macros (in the user's timezone).", inputSchema: {} },
    async () => wrap(await db.rpc("nutrition_day")));

  server.registerTool("get_nutrition_day",
    { description: "Entries, totals, targets, and remaining for a specific date (YYYY-MM-DD).", inputSchema: { date: DATE } },
    async ({ date }) => wrap(await db.rpc("nutrition_day", { p_date: date })));

  server.registerTool("get_nutrition_range",
    { description: "Per-day totals and averages between two dates, inclusive (YYYY-MM-DD).", inputSchema: { start: DATE, end: DATE } },
    async ({ start, end }) => wrap(await db.rpc("nutrition_range", { p_start: start, p_end: end })));

  server.registerTool("get_targets",
    { description: "The user's current daily calorie + macro targets.", inputSchema: {} },
    async () => wrap(await db.from("targets").select("calories,protein_g,carbs_g,fat_g,effective_from")
      .order("effective_from", { ascending: false }).limit(1).maybeSingle()));

  server.registerTool("search_entries",
    { description: "Find logged entries whose description matches text; optional date range.", inputSchema: { query: z.string().min(1).max(200), start: DATE.optional(), end: DATE.optional(), limit: z.number().int().min(1).max(100).optional() } },
    async ({ query, start, end, limit }) => {
      let q = db.from("nutrition_entries").select("*").ilike("description", `%${query}%`);
      if (start) q = q.gte("logged_at", start);
      if (end) q = q.lte("logged_at", end);
      return wrap(await q.order("logged_at", { ascending: false }).limit(limit ?? 25));
    });

  server.registerTool("get_profile",
    { description: "The user's profile: stats, goals, timezone (context for reasoning).", inputSchema: {} },
    async () => wrap(await db.from("profiles").select("*, goals(type,custom_label,priority)").eq("id", userId).maybeSingle()));

  // ── writes (RLS + WITH CHECK enforce ownership) ──────────────────────────
  server.registerTool("log_meal",
    { description: "Log a meal as structured macros. For a photo, analyze it yourself first, then call this. calories=kcal, macros=grams.", inputSchema: { description: DESC, calories: CAL, protein_g: GRAMS, carbs_g: GRAMS, fat_g: GRAMS, meal_type: MEAL.optional(), logged_at: DATE.optional() } },
    async ({ description, calories, protein_g, carbs_g, fat_g, meal_type, logged_at }) => {
      const when = logged_at ? new Date(logged_at) : new Date();
      return wrap(await db.from("nutrition_entries").insert({
        // user_id defaults to auth.uid() in the DB; RLS WITH CHECK verifies it.
        description,
        calories: Math.max(0, Math.round(calories)),
        protein_g: Math.max(0, protein_g),
        carbs_g: Math.max(0, carbs_g),
        fat_g: Math.max(0, fat_g),
        meal_type: meal_type ?? inferMeal(when),
        logged_at: when.toISOString(),
        source: "ai_text",
      }).select().single());
    });

  server.registerTool("update_entry",
    { description: "Update fields of an existing entry by id.", inputSchema: { id: z.string().uuid(), description: DESC.optional(), calories: CAL.optional(), protein_g: GRAMS.optional(), carbs_g: GRAMS.optional(), fat_g: GRAMS.optional(), meal_type: MEAL.optional(), logged_at: DATE.optional() } },
    async ({ id, ...fields }) => {
      const patch = Object.fromEntries(Object.entries(fields).filter(([, v]) => v !== undefined));
      if (Object.keys(patch).length === 0) return fail("No fields to update.");
      return wrap(await db.from("nutrition_entries").update(patch).eq("id", id).select().single());
    });

  server.registerTool("delete_entry",
    { description: "Delete an entry by id.", inputSchema: { id: z.string().uuid() } },
    async ({ id }) => wrap(await db.from("nutrition_entries").delete().eq("id", id).select()));

  server.registerTool("set_targets",
    { description: "Override daily targets (any subset). calories=kcal, macros=grams. Omitted fields keep their computed value.", inputSchema: { calories: CAL.optional(), protein_g: GRAMS.optional(), carbs_g: GRAMS.optional(), fat_g: GRAMS.optional() } },
    async ({ calories, protein_g, carbs_g, fat_g }) => {
      const patch: Record<string, number> = {};
      if (calories !== undefined) patch.tdee_override = Math.round(calories);
      if (protein_g !== undefined) patch.protein_g_override = Math.round(protein_g);
      if (carbs_g !== undefined) patch.carbs_g_override = Math.round(carbs_g);
      if (fat_g !== undefined) patch.fat_g_override = Math.round(fat_g);
      if (Object.keys(patch).length === 0) return fail("Pass at least one target to override.");
      // Writing overrides re-fires the targets trigger.
      return wrap(await db.from("profiles").update(patch).eq("id", userId)
        .select("tdee_override,protein_g_override,carbs_g_override,fat_g_override").single());
    });

  server.registerTool("update_profile",
    { description: "Update profile stats; targets recompute automatically. weight=lb, height=cm, timezone=IANA name.", inputSchema: { weight_lb: z.number().min(0).max(2000).optional(), height_cm: z.number().min(0).max(300).optional(), age: z.number().int().min(0).max(150).optional(), sex: SEX.optional(), training_days_per_week: z.number().int().min(0).max(7).optional(), timezone: z.string().max(64).optional() } },
    async (fields) => {
      const patch = Object.fromEntries(Object.entries(fields).filter(([, v]) => v !== undefined));
      if (Object.keys(patch).length === 0) return fail("No fields to update.");
      return wrap(await db.from("profiles").update(patch).eq("id", userId).select().single());
    });

  server.registerTool("set_goal",
    { description: "Set the user's primary goal; targets recompute automatically.", inputSchema: { type: GOAL, custom_label: z.string().optional() } },
    async ({ type, custom_label }) => {
      const del = await db.from("goals").delete().eq("profile_id", userId);
      if (del.error) return fail(del.error.message);
      return wrap(await db.from("goals").insert({ profile_id: userId, type, custom_label, priority: 0 }).select().single());
    });

  return server;
}

function unauthorized(res: Response) {
  res.set("WWW-Authenticate", `Bearer resource_metadata="${MCP_PUBLIC_URL}/.well-known/oauth-protected-resource"`);
  res.status(401).json({ error: "unauthorized" });
}

const app = express();
app.set("trust proxy", 1); // Fly terminates TLS in front; trust the first hop for real client IPs
app.use(helmet({ contentSecurityPolicy: false })); // CSP off — the consent page loads supabase-js from a CDN
app.use(express.json({ limit: "1mb" }));
app.use(rateLimit({ windowMs: 60_000, limit: 120, standardHeaders: true, legacyHeaders: false }));

app.get("/health", (_req, res) => res.json({ ok: true }));

// RFC 9728 Protected Resource Metadata → points clients at the Supabase OAuth AS.
app.get("/.well-known/oauth-protected-resource", (_req, res) => {
  res.json({
    resource: `${MCP_PUBLIC_URL}/mcp`,
    authorization_servers: [ISSUER],
    scopes_supported: ["openid", "email", "profile"],
    resource_name: "Nutrition App For AI",
  });
});

// OAuth consent screen (Supabase OAuth Server redirects users here with ?authorization_id=).
// Public config for the browser supabase-js client (publishable key is safe client-side).
app.get("/oauth/config.json", (_req, res) => {
  res.json({ url: SUPABASE_URL, key: SUPABASE_PUBLISHABLE_KEY });
});
app.get("/oauth/consent", (_req, res) => {
  res.sendFile(path.resolve("public/consent.html"));
});

app.post("/mcp", async (req: Request, res: Response) => {
  const auth = req.headers.authorization ?? "";
  if (!auth.startsWith("Bearer ")) return unauthorized(res);
  let userId: string;
  try { userId = await verify(auth.slice(7)); } catch { return unauthorized(res); }

  try {
    const server = buildServer(auth.slice(7), userId);
    const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
    res.on("close", () => { transport.close(); server.close(); });
    await server.connect(transport);
    await transport.handleRequest(req, res, req.body);
  } catch (e) {
    console.error("mcp handler error:", e);
    if (!res.headersSent) res.status(500).json({ error: "internal_error" });
  }
});

app.listen(PORT, () => console.log(`nutrition MCP server listening on :${PORT}`));
