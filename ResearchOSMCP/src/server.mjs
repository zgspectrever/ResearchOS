#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { createMcpExpressApp } from "@modelcontextprotocol/sdk/server/express.js";
import { registerResearchTools } from "./research-tools.mjs";

const mode = process.argv.includes("--stdio") ? "stdio" : "http";
const host = process.env.RESEARCHOS_MCP_HOST ?? "127.0.0.1";
const port = Number(process.env.RESEARCHOS_MCP_PORT ?? 31999);

function createServer() {
  const server = new McpServer({ name: "ResearchOS", version: "0.1.0" });
  registerResearchTools(server);
  return server;
}

async function runStdio() {
  const server = createServer();
  await server.connect(new StdioServerTransport());
  console.error("ResearchOS MCP is running over stdio.");
}

async function runHTTP() {
  const app = createMcpExpressApp({ host });
  app.get("/health", (_request, response) => {
    response.json({ ok: true, service: "ResearchOS MCP", version: "0.1.0" });
  });
  app.post("/mcp", async (request, response) => {
    const server = createServer();
    const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
    response.on("close", () => {
      void transport.close();
      void server.close();
    });
    try {
      await server.connect(transport);
      await transport.handleRequest(request, response, request.body);
    } catch (error) {
      console.error("MCP request failed:", error);
      if (!response.headersSent) response.status(500).json({ jsonrpc: "2.0", error: { code: -32603, message: "Internal server error" }, id: null });
    }
  });
  const methodNotAllowed = (_request, response) => response.status(405).json({
    jsonrpc: "2.0", error: { code: -32000, message: "Method not allowed" }, id: null,
  });
  app.get("/mcp", methodNotAllowed);
  app.delete("/mcp", methodNotAllowed);
  app.listen(port, host, error => {
    if (error) throw error;
    console.error(`ResearchOS MCP listening at http://${host}:${port}/mcp`);
  });
}

try {
  if (mode === "stdio") await runStdio();
  else await runHTTP();
} catch (error) {
  console.error(error);
  process.exit(1);
}
