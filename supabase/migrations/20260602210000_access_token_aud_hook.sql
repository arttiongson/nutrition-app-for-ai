-- RFC 8707 audience binding for the MCP resource server (Phase 3 hardening).
-- Supabase's Custom Access Token Hook: stamps the MCP server's canonical URL into the token's
-- `aud`, AS AN ARRAY that keeps "authenticated" so Supabase/PostgREST still accept the token.
-- The MCP server then validates that its URL is present in `aud` (defense vs. token replay to
-- another resource). RLS remains the real boundary.
create or replace function public.custom_access_token_hook(event jsonb)
returns jsonb
language plpgsql
as $$
declare
  claims jsonb := coalesce(event -> 'claims', '{}'::jsonb);
begin
  claims := jsonb_set(claims, '{aud}', '["authenticated", "https://nutrition-mcp-for-ai.fly.dev/mcp"]'::jsonb);
  return jsonb_set(event, '{claims}', claims);
end;
$$;

-- Only Supabase Auth may run the hook.
grant execute on function public.custom_access_token_hook(jsonb) to supabase_auth_admin;
revoke execute on function public.custom_access_token_hook(jsonb) from authenticated, anon, public;
