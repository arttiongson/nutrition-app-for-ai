// Full OAuth loop, programmatically — proves the consent flow end-to-end (the script
// "clicks Approve" instead of a human). Needs SUPABASE_URL + PUBKEY in env.
import { createClient } from "@supabase/supabase-js";
import crypto from "node:crypto";

const SUPABASE_URL = process.env.SUPABASE_URL;
const PUBKEY = process.env.PUBKEY;
const AS = `${SUPABASE_URL}/auth/v1`;
const REDIRECT = "http://localhost:8976/callback";
const MCP = "https://nutrition-mcp-for-ai.fly.dev/mcp";

const b64url = (b) => b.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const verifier = b64url(crypto.randomBytes(32));
const challenge = b64url(crypto.createHash("sha256").update(verifier).digest());

const supabase = createClient(SUPABASE_URL, PUBKEY, { auth: { persistSession: false, autoRefreshToken: false } });

// 0. sign up a throwaway user (autoconfirm is on → instant session)
const email = `e2e+${Date.now()}@example.com`, password = "Test12345!";
let { data: su, error: sue } = await supabase.auth.signUp({ email, password });
if (sue) throw new Error("signup: " + sue.message);
if (!su.session) {
  const r = await supabase.auth.signInWithPassword({ email, password });
  if (r.error) throw new Error("signin: " + r.error.message);
}
console.log("0. user:", email);

// 1. dynamic client registration
const reg = await (await fetch(`${AS}/oauth/clients/register`, {
  method: "POST", headers: { "Content-Type": "application/json", apikey: PUBKEY },
  body: JSON.stringify({ client_name: "e2e", redirect_uris: [REDIRECT], grant_types: ["authorization_code", "refresh_token"], response_types: ["code"], token_endpoint_auth_method: "none" }),
})).json();
const clientId = reg.client_id;
console.log("1. DCR client_id:", clientId || JSON.stringify(reg));

// 2. /authorize → consent redirect with authorization_id
const authzUrl = `${AS}/oauth/authorize?response_type=code&client_id=${clientId}&redirect_uri=${encodeURIComponent(REDIRECT)}&scope=${encodeURIComponent("openid email profile")}&code_challenge=${challenge}&code_challenge_method=S256&state=xyz`;
const ar = await fetch(authzUrl, { redirect: "manual", headers: { apikey: PUBKEY } });
const authId = new URL(ar.headers.get("location")).searchParams.get("authorization_id");
console.log("2. authorize → authId:", authId);

// 3. consent page reads the request
const det = await supabase.auth.oauth.getAuthorizationDetails(authId);
console.log("3. getAuthorizationDetails:", det.error ? "ERR " + det.error.message : JSON.stringify({ client: det.data?.client?.name, scope: det.data?.scope }));

// 4. consent page approves → redirect_url carries the code
const appr = await supabase.auth.oauth.approveAuthorization(authId);
if (appr.error) throw new Error("approve: " + appr.error.message);
const code = new URL(appr.data.redirect_url).searchParams.get("code");
console.log("4. approved → code:", code ? code.slice(0, 10) + "…" : "(none)");

// 5. exchange code → access token
const tok = await (await fetch(`${AS}/oauth/token`, {
  method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded", apikey: PUBKEY },
  body: new URLSearchParams({ grant_type: "authorization_code", code, redirect_uri: REDIRECT, client_id: clientId, code_verifier: verifier }),
})).json();
console.log("5. token:", tok.access_token ? `ISSUED (expires_in ${tok.expires_in}, refresh ${tok.refresh_token ? "yes" : "no"})` : JSON.stringify(tok));

// 6. use the OAuth-issued token against the live MCP server
if (tok.access_token) {
  const { Client } = await import("@modelcontextprotocol/sdk/client/index.js");
  const { StreamableHTTPClientTransport } = await import("@modelcontextprotocol/sdk/client/streamableHttp.js");
  const client = new Client({ name: "e2e", version: "0.0.1" });
  await client.connect(new StreamableHTTPClientTransport(new URL(MCP), { requestInit: { headers: { Authorization: `Bearer ${tok.access_token}` } } }));
  const r = await client.callTool({ name: "get_nutrition_today", arguments: {} });
  console.log("6. MCP get_nutrition_today via OAuth token:", r.content?.[0]?.text?.slice(0, 90));
  await client.close();
}
console.log("CLEANUP_EMAIL=" + email);
