// Phase 2 — POST /log
// One shared parsing path for the iOS app AND the agent's MCP `log_meal` tool.
// Input (JSON):  { text?, image_base64?, mime_type?, note?, meal_type?, logged_at? }
// Flow: auth (caller's JWT) → optional downscale → Gemini parse → RLS-scoped insert → return row.
// The Gemini key lives ONLY here (Supabase secret); it never reaches a client.
//
// Deploy:  npx supabase functions deploy log --project-ref <ref>   (verify_jwt stays ON)
// Secret:  npx supabase secrets set GEMINI_API_KEY=...

import { createClient } from "jsr:@supabase/supabase-js@2";

const GEMINI_API_KEY = Deno.env.get("GEMINI_API_KEY")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
// New key model injects PUBLISHABLE; older projects inject ANON. Accept either.
const PUBLISHABLE_KEY =
  Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY")!;

const PARSE_MODEL = "gemini-3.1-flash-lite";        // fast/cheap default
const ESCALATION_MODEL = "gemini-3.5-flash";        // stronger model for low-confidence parses
const ESCALATION_THRESHOLD = 0.6;                   // below this confidence, re-parse on the stronger model
const GEMINI_URL = (model: string) =>
  `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`;

// Mirrors AIParsedNutrition (+ meal_type). responseMimeType+responseSchema verified working.
const RESPONSE_SCHEMA = {
  type: "object",
  properties: {
    description: { type: "string" },
    calories: { type: "integer" },
    protein_g: { type: "number" },
    carbs_g: { type: "number" },
    fat_g: { type: "number" },
    meal_type: { type: "string", enum: ["breakfast", "lunch", "dinner", "snack"] },
    confidence: { type: "number" },
  },
  required: ["description", "calories", "protein_g", "carbs_g", "fat_g", "confidence"],
};

const SYSTEM = `You estimate the nutrition of a meal from text and/or a photo.
Estimate totals for the FULL portion shown. Use typical portions when unsure
(chicken breast ~5-6oz, cooked rice ~1 cup, dressing ~2 tbsp). Count every visible
or named item. Keep macros internally consistent: protein*4 + carbs*4 + fat*9 ≈ calories.
Set confidence 0..1: ~0.85+ for a clear nutrition label or precise text, ~0.55-0.75 for a
typical meal photo with a description, <0.3 when there's little to go on. If a meal_type is
obvious, set it. Respond ONLY with JSON matching the schema.`;

// Port of MealTypeInference: hour-of-day → meal_type.
function inferMealType(d: Date): string {
  const h = d.getHours();
  if (h >= 4 && h < 11) return "breakfast";
  if (h >= 11 && h < 15) return "lunch";
  if (h >= 17 && h < 21) return "dinner";
  return "snack";
}

// Downscale to ~768px longest side to cut Gemini image tokens. Defensive: any failure
// (unknown format, decode error) falls back to the original bytes — correctness over savings.
async function downscaleToBase64(b64: string): Promise<string> {
  try {
    const { decode } = await import("https://deno.land/x/imagescript@1.3.0/mod.ts");
    const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
    const img = await decode(bytes);
    const longest = Math.max(img.width, img.height);
    if (longest > 768) {
      const scale = 768 / longest;
      img.resize(Math.round(img.width * scale), Math.round(img.height * scale));
    }
    const jpeg = await img.encodeJPEG(80);
    return btoa(String.fromCharCode(...jpeg));
  } catch (_e) {
    return b64; // fall back to original on any decode/resize failure
  }
}

async function parseWithGemini(opts: {
  model: string; text?: string; note?: string; imageB64?: string; mimeType?: string;
}) {
  const parts: unknown[] = [];
  if (opts.imageB64) {
    parts.push({ inline_data: { mime_type: opts.mimeType ?? "image/jpeg", data: opts.imageB64 } });
  }
  const userText = [opts.text, opts.note].filter(Boolean).join(" — ") || "Estimate this meal.";
  parts.push({ text: userText });

  const body = {
    systemInstruction: { parts: [{ text: SYSTEM }] },
    contents: [{ parts }],
    generationConfig: { responseMimeType: "application/json", responseSchema: RESPONSE_SCHEMA },
  };

  // Retry transient errors (429/500/503 — e.g. "model experiencing high demand") with backoff.
  const RETRYABLE = new Set([429, 500, 503]);
  let json;
  for (let attempt = 0; ; attempt++) {
    if (attempt > 0) await new Promise((r) => setTimeout(r, 500 * attempt));
    const res = await fetch(GEMINI_URL(opts.model), {
      method: "POST",
      headers: { "x-goog-api-key": GEMINI_API_KEY, "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (res.ok) { json = await res.json(); break; }
    const err = `Gemini ${res.status}: ${(await res.text()).slice(0, 200)}`;
    if (!RETRYABLE.has(res.status) || attempt >= 2) throw new Error(err);
  }
  // pick the part that carries text (Gemini 3 may also emit a thought part)
  const textPart = json?.candidates?.[0]?.content?.parts?.find((p: { text?: string }) => p.text)?.text;
  if (!textPart) throw new Error("Gemini returned no text part");
  return JSON.parse(textPart);
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return new Response("Missing Authorization", { status: 401 });

  // Scope the client to the caller — every DB op now runs under their RLS.
  const supabase = createClient(SUPABASE_URL, PUBLISHABLE_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error: userErr } = await supabase.auth.getUser();
  if (userErr || !user) return new Response("Invalid token", { status: 401 });

  let payload: Record<string, unknown>;
  try { payload = await req.json(); }
  catch { return new Response("Body must be JSON", { status: 400 }); }

  const text = payload.text as string | undefined;
  const note = payload.note as string | undefined;
  let imageB64 = payload.image_base64 as string | undefined;
  const mimeType = payload.mime_type as string | undefined;
  if (!text && !imageB64) return new Response("Provide text or image_base64", { status: 400 });

  if (imageB64) imageB64 = await downscaleToBase64(imageB64);

  let parsed;
  try { parsed = await parseWithGemini({ model: PARSE_MODEL, text, note, imageB64, mimeType }); }
  catch (e) { return new Response(`Parse failed: ${e}`, { status: 502 }); }

  // 2.5 — confidence-gated escalation. A low-confidence parse gets ONE retry on the stronger
  // model; synchronous, so the returned row is already the better result. Falls back to the
  // flash-lite result if the escalation call itself fails.
  let parserModel = PARSE_MODEL;
  if (typeof parsed.confidence === "number" && parsed.confidence < ESCALATION_THRESHOLD) {
    try {
      parsed = await parseWithGemini({ model: ESCALATION_MODEL, text, note, imageB64, mimeType });
      parserModel = ESCALATION_MODEL;
    } catch (_e) { /* escalation model unavailable after retries — keep the flash-lite result */ }
  }

  const loggedAt = payload.logged_at ? new Date(payload.logged_at as string) : new Date();
  const mealType =
    (payload.meal_type as string | undefined) ?? parsed.meal_type ?? inferMealType(loggedAt);
  const source = imageB64 ? "ai_photo" : "ai_text";

  const { data: row, error: insErr } = await supabase
    .from("nutrition_entries")
    .insert({
      user_id: user.id,
      logged_at: loggedAt.toISOString(),
      meal_type: mealType,
      description: parsed.description ?? "",
      calories: Math.max(0, Math.round(parsed.calories ?? 0)),
      protein_g: Math.max(0, parsed.protein_g ?? 0),
      carbs_g: Math.max(0, parsed.carbs_g ?? 0),
      fat_g: Math.max(0, parsed.fat_g ?? 0),
      source,
      ai_confidence: parsed.confidence ?? null,
    })
    .select()
    .single();

  if (insErr) return new Response(`Insert failed: ${insErr.message}`, { status: 400 });
  return new Response(JSON.stringify(row), {
    status: 201,
    headers: { "Content-Type": "application/json", "X-Parser-Model": parserModel },
  });
});
