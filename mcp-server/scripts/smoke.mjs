// End-to-end smoke test against the deployed MCP server using a real MCP client.
// Usage: TEST_JWT=<supabase user jwt> MCP_URL=<url> node scripts/smoke.mjs
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

const url = new URL(process.env.MCP_URL ?? "https://nutrition-mcp-for-ai.fly.dev/mcp");
const token = process.env.TEST_JWT;
if (!token) throw new Error("TEST_JWT required");

const transport = new StreamableHTTPClientTransport(url, {
  requestInit: { headers: { Authorization: `Bearer ${token}` } },
});
const client = new Client({ name: "smoke", version: "0.0.1" });

await client.connect(transport);
console.log("connected (initialize OK)");

const tools = await client.listTools();
console.log("tools:", tools.tools.map((t) => t.name).join(", "));

const today = await client.callTool({ name: "get_nutrition_today", arguments: {} });
console.log("today (before):", today.content?.[0]?.text?.slice(0, 200));

const logged = await client.callTool({
  name: "log_meal",
  arguments: { description: "smoke-test chicken bowl", calories: 700, protein_g: 50, carbs_g: 70, fat_g: 20, meal_type: "lunch" },
});
console.log("log_meal:", logged.isError ? "ERROR " + logged.content?.[0]?.text : "ok");

const today2 = await client.callTool({ name: "get_nutrition_today", arguments: {} });
console.log("today (after):", today2.content?.[0]?.text?.slice(0, 300));

await client.close();
console.log("done");
