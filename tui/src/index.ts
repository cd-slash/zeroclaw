#!/usr/bin/env node
import { createCliRenderer, Box, Text, Input, SelectRenderable, SelectRenderableEvents, ScrollBox, Button } from "@opentui/core";
import { execSync, spawn } from "child_process";
import { readFileSync, writeFileSync, existsSync, readdirSync, mkdirSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT_DIR = join(__dirname, "..", "..");
const AGENTS_DIR = join(ROOT_DIR, ".agents");

interface Agent {
  name: string;
  status: "running" | "stopped" | "unknown";
  config: Record<string, string>;
  identityFiles: string[];
}

// Utility functions
function getAgents(): Agent[] {
  const agents: Agent[] = [];
  
  try {
    const entries = readdirSync(AGENTS_DIR, { withFileTypes: true });
    
    for (const entry of entries) {
      if (entry.isDirectory() && !entry.name.startsWith(".") && entry.name !== "templates") {
        const agentName = entry.name;
        const agentDir = join(AGENTS_DIR, agentName);
        const envPath = join(agentDir, ".env");
        
        let status: Agent["status"] = "stopped";
        try {
          execSync(`docker compose -f docker-compose.agents.yml ps ${agentName}`, { 
            cwd: ROOT_DIR,
            stdio: "pipe" 
          });
          const ps = execSync(`docker compose -f docker-compose.agents.yml ps ${agentName} --format json`, {
            cwd: ROOT_DIR,
            encoding: "utf-8",
            stdio: "pipe"
          });
          if (ps.includes("running")) {
            status = "running";
          }
        } catch {
          status = "stopped";
        }
        
        let config: Record<string, string> = {};
        if (existsSync(envPath)) {
          const envContent = readFileSync(envPath, "utf-8");
          config = parseEnv(envContent);
        }
        
        const identityFiles = readdirSync(agentDir)
          .filter(f => f.endsWith(".md"))
          .map(f => join(agentDir, f));
        
        agents.push({ name: agentName, status, config, identityFiles });
      }
    }
  } catch (error) {
    console.error("Error reading agents:", error);
  }
  
  return agents.sort((a, b) => a.name.localeCompare(b.name));
}

function parseEnv(content: string): Record<string, string> {
  const result: Record<string, string> = {};
  for (const line of content.split("\n")) {
    const match = line.match(/^([^#=]+)=(.*)$/);
    if (match) {
      result[match[1].trim()] = match[2].trim();
    }
  }
  return result;
}

function stringifyEnv(config: Record<string, string>): string {
  return Object.entries(config)
    .map(([key, value]) => `${key}=${value}`)
    .join("\n");
}

function getAgentStatusColor(status: Agent["status"]): string {
  switch (status) {
    case "running": return "#00FF00";
    case "stopped": return "#FF0000";
    default: return "#FFFF00";
  }
}

// Views
class AgentListView {
  private renderer: any;
  private agents: Agent[] = [];
  private select: any;
  private onSelect: (agent: Agent) => void;
  private onCreate: () => void;
  private refreshCallback: () => void;

  constructor(
    renderer: any, 
    onSelect: (agent: Agent) => void,
    onCreate: () => void
  ) {
    this.renderer = renderer;
    this.onSelect = onSelect;
    this.onCreate = onCreate;
    this.refreshCallback = this.refresh.bind(this);
  }

  render() {
    this.agents = getAgents();
    
    const options = [
      ...this.agents.map(agent => ({
        name: `${agent.status === "running" ? "●" : "○"} ${agent.name}`,
        description: `Status: ${agent.status}`,
        agent
      })),
      { name: "+ Create New Agent", description: "Add a new agent", agent: null }
    ];

    this.select = new SelectRenderable(this.renderer, {
      id: "agent-list",
      width: 50,
      height: 20,
      options: options.map(opt => ({ 
        name: opt.name, 
        description: opt.description 
      })),
      border: true,
      title: "ZeroClaw Agents",
      titleAlignment: "center",
    });

    this.select.on(SelectRenderableEvents.ITEM_SELECTED, (index: number) => {
      if (index < this.agents.length) {
        this.onSelect(this.agents[index]);
      } else {
        this.onCreate();
      }
    });

    this.select.focus();

    return Box(
      { 
        width: 60, 
        height: 24, 
        border: true, 
        padding: 1,
        flexDirection: "column",
        gap: 1
      },
      Text({ content: "ZeroClaw Agent Manager", bold: true, color: "#00FFFF" }),
      Text({ content: "Use ↑/↓ to navigate, Enter to select, q to quit", color: "#888888" }),
      this.select
    );
  }

  refresh() {
    this.agents = getAgents();
    // Re-render with new data
    this.renderer.root.clear();
    this.renderer.root.add(this.render());
  }
}

class AgentEditorView {
  private renderer: any;
  private agent: Agent;
  private onBack: () => void;
  private currentTab: "config" | "soul" | "identity" | "tools" = "config";
  private contentBox: any;

  constructor(renderer: any, agent: Agent, onBack: () => void) {
    this.renderer = renderer;
    this.agent = agent;
    this.onBack = onBack;
  }

  render() {
    const tabs = ["config", "soul", "identity", "tools"];
    const tabButtons = tabs.map(tab => 
      Button({
        content: tab.toUpperCase(),
        onClick: () => {
          this.currentTab = tab as any;
          this.refreshContent();
        },
        backgroundColor: this.currentTab === tab ? "#00FFFF" : "#333333",
        textColor: this.currentTab === tab ? "#000000" : "#FFFFFF",
        width: 12
      })
    );

    this.contentBox = Box({
      width: 70,
      height: 18,
      border: true,
      padding: 1,
      flexDirection: "column",
      gap: 1
    });

    this.refreshContent();

    const statusColor = getAgentStatusColor(this.agent.status);

    return Box(
      {
        width: 80,
        height: 26,
        border: true,
        padding: 1,
        flexDirection: "column",
        gap: 1
      },
      Box(
        { flexDirection: "row", gap: 2 },
        Text({ content: `Agent: ${this.agent.name}`, bold: true, color: "#00FFFF" }),
        Text({ content: `● ${this.agent.status}`, color: statusColor })
      ),
      Box(
        { flexDirection: "row", gap: 1 },
        ...tabButtons,
        Button({
          content: "BACK",
          onClick: this.onBack,
          backgroundColor: "#FF0000",
          width: 10
        })
      ),
      this.contentBox
    );
  }

  refreshContent() {
    this.contentBox.clear();
    
    switch (this.currentTab) {
      case "config":
        this.renderConfigTab();
        break;
      case "soul":
        this.renderSoulTab();
        break;
      case "identity":
        this.renderIdentityTab();
        break;
      case "tools":
        this.renderToolsTab();
        break;
    }
  }

  renderConfigTab() {
    const envPath = join(AGENTS_DIR, this.agent.name, ".env");
    
    const inputs = Object.entries(this.agent.config).map(([key, value], index) =>
      Box(
        { flexDirection: "row", gap: 1 },
        Text({ content: `${key}:`, width: 25 }),
        Input({
          id: `config-${key}`,
          value: value,
          width: 40,
          onChange: (newValue: string) => {
            this.agent.config[key] = newValue;
          }
        })
      )
    );

    const actionButtons = Box(
      { flexDirection: "row", gap: 2, marginTop: 1 },
      Button({
        content: this.agent.status === "running" ? "STOP" : "START",
        onClick: () => {
          try {
            if (this.agent.status === "running") {
              execSync(`./scripts/agent.sh stop ${this.agent.name}`, { cwd: ROOT_DIR });
            } else {
              execSync(`./scripts/agent.sh start ${this.agent.name}`, { cwd: ROOT_DIR });
            }
            // Refresh agent status
            this.agent = getAgents().find(a => a.name === this.agent.name) || this.agent;
            this.renderer.root.clear();
            this.renderer.root.add(this.render());
          } catch (e) {
            console.error("Action failed:", e);
          }
        },
        backgroundColor: this.agent.status === "running" ? "#FF0000" : "#00FF00",
        width: 15
      }),
      Button({
        content: "SAVE",
        onClick: () => {
          try {
            writeFileSync(envPath, stringifyEnv(this.agent.config));
            console.log("Configuration saved!");
          } catch (e) {
            console.error("Save failed:", e);
          }
        },
        backgroundColor: "#00FFFF",
        width: 15
      }),
      Button({
        content: "VIEW LOGS",
        onClick: () => {
          // Open logs in separate process
          spawn("./scripts/agent.sh", ["logs", this.agent.name, "-f"], {
            cwd: ROOT_DIR,
            stdio: "inherit",
            detached: true
          });
        },
        backgroundColor: "#888888",
        width: 15
      })
    );

    this.contentBox.add(
      Box(
        { flexDirection: "column", gap: 1 },
        Text({ content: "Configuration (.env)", bold: true, color: "#00FFFF" }),
        ScrollBox(
          { height: 12, width: 68 },
          Box(
            { flexDirection: "column", gap: 1 },
            ...inputs
          )
        ),
        actionButtons
      )
    );
  }

  renderSoulTab() {
    const soulPath = join(AGENTS_DIR, this.agent.name, "SOUL.md");
    let content = "";
    
    try {
      if (existsSync(soulPath)) {
        content = readFileSync(soulPath, "utf-8");
      }
    } catch (e) {
      content = "Error reading SOUL.md";
    }

    this.contentBox.add(
      Box(
        { flexDirection: "column", gap: 1 },
        Text({ content: "SOUL.md - Personality & Behavior", bold: true, color: "#FF00FF" }),
        Text({ content: content.substring(0, 500) + (content.length > 500 ? "..." : "") }),
        Button({
          content: "EDIT IN $EDITOR",
          onClick: () => {
            const editor = process.env.EDITOR || "nano";
            spawn(editor, [soulPath], { stdio: "inherit" });
          },
          backgroundColor: "#00FFFF"
        })
      )
    );
  }

  renderIdentityTab() {
    const identityPath = join(AGENTS_DIR, this.agent.name, "IDENTITY.md");
    let content = "";
    
    try {
      if (existsSync(identityPath)) {
        content = readFileSync(identityPath, "utf-8");
      }
    } catch (e) {
      content = "Error reading IDENTITY.md";
    }

    this.contentBox.add(
      Box(
        { flexDirection: "column", gap: 1 },
        Text({ content: "IDENTITY.md - Who the agent is", bold: true, color: "#FFFF00" }),
        Text({ content: content.substring(0, 500) + (content.length > 500 ? "..." : "") }),
        Button({
          content: "EDIT IN $EDITOR",
          onClick: () => {
            const editor = process.env.EDITOR || "nano";
            spawn(editor, [identityPath], { stdio: "inherit" });
          },
          backgroundColor: "#00FFFF"
        })
      )
    );
  }

  renderToolsTab() {
    const toolsDir = join(AGENTS_DIR, this.agent.name, "tools");
    let tools: string[] = [];
    
    try {
      if (existsSync(toolsDir)) {
        tools = readdirSync(toolsDir).filter(f => !f.startsWith("."));
      }
    } catch (e) {
      tools = [];
    }

    const aptPackages = this.agent.config.AGENT_APT_PACKAGES || "";
    const npmPackages = this.agent.config.AGENT_NPM_PACKAGES || "";

    this.contentBox.add(
      Box(
        { flexDirection: "column", gap: 1 },
        Text({ content: "Tools & Packages", bold: true, color: "#00FF00" }),
        
        Text({ content: "APT Packages:", bold: true }),
        Input({
          id: "apt-packages",
          value: aptPackages,
          width: 60,
          onChange: (value: string) => {
            this.agent.config.AGENT_APT_PACKAGES = value;
          }
        }),
        
        Text({ content: "NPM Packages:", bold: true }),
        Input({
          id: "npm-packages",
          value: npmPackages,
          width: 60,
          onChange: (value: string) => {
            this.agent.config.AGENT_NPM_PACKAGES = value;
          }
        }),
        
        Text({ content: `Custom Tools (${tools.length}):`, bold: true }),
        ...tools.map(tool => Text({ content: `  • ${tool}` })),
        
        Button({
          content: "OPEN TOOLS DIRECTORY",
          onClick: () => {
            console.log(`\nTools directory: ${toolsDir}`);
            console.log("Add executable files here to make them available to the agent.\n");
          },
          backgroundColor: "#888888"
        })
      )
    );
  }
}

class CreateAgentView {
  private renderer: any;
  private onBack: () => void;
  private onCreate: (name: string) => void;

  constructor(renderer: any, onBack: () => void, onCreate: (name: string) => void) {
    this.renderer = renderer;
    this.onBack = onBack;
    this.onCreate = onCreate;
  }

  render() {
    let agentName = "";

    const nameInput = Input({
      id: "new-agent-name",
      placeholder: "Enter agent name...",
      width: 30,
      onChange: (value: string) => {
        agentName = value;
      }
    });

    return Box(
      {
        width: 50,
        height: 15,
        border: true,
        padding: 2,
        flexDirection: "column",
        gap: 1
      },
      Text({ content: "Create New Agent", bold: true, color: "#00FFFF" }),
      Text({ content: "Agent name:" }),
      nameInput,
      Box(
        { flexDirection: "row", gap: 2, marginTop: 1 },
        Button({
          content: "CREATE",
          onClick: () => {
            if (agentName.trim()) {
              this.onCreate(agentName.trim());
            }
          },
          backgroundColor: "#00FF00",
          width: 15
        }),
        Button({
          content: "CANCEL",
          onClick: this.onBack,
          backgroundColor: "#FF0000",
          width: 15
        })
      )
    );
  }
}

// Main App
async function main() {
  const renderer = await createCliRenderer();
  let currentView: "list" | "editor" | "create" = "list";
  let selectedAgent: Agent | null = null;

  function showList() {
    currentView = "list";
    renderer.root.clear();
    
    const listView = new AgentListView(
      renderer,
      (agent) => {
        selectedAgent = agent;
        showEditor();
      },
      () => {
        showCreate();
      }
    );
    
    renderer.root.add(listView.render());
  }

  function showEditor() {
    if (!selectedAgent) return;
    currentView = "editor";
    renderer.root.clear();
    
    const editorView = new AgentEditorView(renderer, selectedAgent, () => {
      selectedAgent = null;
      showList();
    });
    
    renderer.root.add(editorView.render());
  }

  function showCreate() {
    currentView = "create";
    renderer.root.clear();
    
    const createView = new CreateAgentView(
      renderer,
      () => showList(),
      (name) => {
        try {
          execSync(`./scripts/agent.sh create ${name}`, { cwd: ROOT_DIR });
          console.log(`Agent "${name}" created successfully!`);
          showList();
        } catch (e) {
          console.error("Failed to create agent:", e);
          showList();
        }
      }
    );
    
    renderer.root.add(createView.render());
  }

  // Handle quit
  process.stdin.on("keypress", (str, key) => {
    if (key.name === "q" && currentView === "list") {
      renderer.stop();
      process.exit(0);
    }
  });

  showList();
}

main().catch(console.error);
