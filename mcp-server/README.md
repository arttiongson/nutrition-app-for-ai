# Nutrition MCP Server

Hosted MCP server that lets a user's agent read and write their nutrition data, confined to
their own rows by Postgres RLS. OAuth 2.1 resource server backed by Supabase. See
[../PHASE_3_MCP.md](../PHASE_3_MCP.md) for the full scope.

- **Transport:** Streamable HTTP (`POST /mcp`)
- **Auth:** validates a Supabase-issued JWT via the project JWKS (`jose`); forwards it to
  Supabase so RLS applies. No service key, no Gemini key.
- **Tools:** reads (`get_nutrition_today/day/range`, `get_targets`, `search_entries`,
  `get_profile`) + writes (`log_meal`, `update_entry`, `delete_entry`, `set_targets`,
  `update_profile`, `set_goal`).

## Run locally
```bash
npm install
cp .env.example .env   # fill in values
npm run dev
```

## Connect an agent
```bash
claude mcp add --transport http nutrition https://<your-host>/mcp
# then `/mcp` in a session → browser OAuth against Supabase
```

## Deploy
Any long-running Node host (Fly.io / Railway). Set the env vars from `.env.example`.
