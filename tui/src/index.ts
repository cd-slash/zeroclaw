#!/usr/bin/env node
import { execSync } from "child_process";
import { readdirSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT_DIR = join(__dirname, "..", "..");
const AGENTS_DIR = join(ROOT_DIR, ".agents");

interface Agent {
  name: string;
  status: "running" | "stopped";
}

function getAgents(): Agent[] {
  const agents: Agent[] = [];
  
  try {
    const entries = readdirSync(AGENTS_DIR, { withFileTypes: true });
    
    for (const entry of entries) {
      if (entry.isDirectory() && !entry.name.startsWith(".") && entry.name !== "templates") {
        const agentName = entry.name;
        
        let status: Agent["status"] = "stopped";
        try {
          const result = execSync(
            `docker compose -f docker-compose.agents.yml ps ${agentName} 2>/dev/null || echo ""`,
            { cwd: ROOT_DIR, encoding: "utf-8", stdio: "pipe" }
          );
          if (result.includes("running")) {
            status = "running";
          }
        } catch {
          status = "stopped";
        }
        
        agents.push({ name: agentName, status });
      }
    }
  } catch (error) {
    console.error("Error reading agents:", error);
  }
  
  return agents.sort((a, b) => a.name.localeCompare(b.name));
}

async function main() {
  console.log("🦀 ZeroClaw Agent Manager");
  console.log("==========================\n");
  
  const agents = getAgents();
  
  if (agents.length === 0) {
    console.log("No agents found.");
    console.log("\nTo create an agent:");
    console.log("  ./scripts/agent.sh create <name>");
    return;
  }
  
  console.log("Available agents:\n");
  agents.forEach((agent, i) => {
    const status = agent.status === "running" ? "● running" : "○ stopped";
    console.log(`  ${i + 1}. ${agent.name.padEnd(15)} ${status}`);
  });
  
  console.log("\n\nCommands:");
  console.log("  ./scripts/agent.sh start <name>     - Start an agent");
  console.log("  ./scripts/agent.sh stop <name>      - Stop an agent");
  console.log("  ./scripts/agent.sh logs <name> -f   - View logs");
  console.log("  ./scripts/agent.sh shell <name>     - Open shell");
  console.log("  ./scripts/agent.sh create <name>    - Create new agent");
  console.log("\n");
}

main().catch(console.error);
