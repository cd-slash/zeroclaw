#!/usr/bin/env bun
import { spawn, spawnSync, type ChildProcessWithoutNullStreams } from "node:child_process";
import {
  copyFileSync,
  cpSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import {
  BoxRenderable,
  InputRenderable,
  ScrollBoxRenderable,
  TextRenderable,
  TextareaRenderable,
  createCliRenderer,
} from "@opentui/core";

type AgentStatus = "running" | "stopped" | "unknown";

type View = "dashboard" | "env" | "identity" | "skills" | "tools" | "logs" | "ops";

interface AgentInfo {
  name: string;
  dir: string;
  envPath: string;
  status: AgentStatus;
}

interface PromptState {
  title: string;
  placeholder: string;
  initialValue?: string;
  handler: (value: string) => void;
}

interface EnvModalState {
  focus: "key" | "value";
}

interface ToolCatalogItem {
  id: string;
  name: string;
  description: string;
  binary: string;
  sourcePath: string;
}

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const ROOT_DIR = join(__dirname, "../..");
const AGENTS_DIR = join(ROOT_DIR, ".agents");
const AGENT_SCRIPT = join(ROOT_DIR, "scripts/agent.sh");
const BACKUP_SCRIPT = join(ROOT_DIR, "scripts/agent-backup.sh");
const LITESTREAM_SCRIPT = join(ROOT_DIR, "scripts/litestream.sh");
const BACKUPS_DIR = join(ROOT_DIR, ".backups");
const AGENT_TOOLS_REPO = join(ROOT_DIR, "../agent-tools");

const THEME = {
  bg: "#0b1018",
  panel: "#142033",
  panelAlt: "#111b2b",
  border: "#3a557a",
  borderSoft: "#314968",
  text: "#ebf2ff",
  textMuted: "#c6d6ef",
  accent: "#60a5fa",
  success: "#34d399",
  warning: "#fbbf24",
  danger: "#fb7185",
  editorBg: "#0c1627",
  editorFocusBg: "#0d2038",
  promptBg: "#152239",
  envModalBg: "#143126",
};

const TAB_PAD_X = 2;
const TAB_PAD_Y = 1;

const VIEWS: Array<{ key: View; label: string }> = [
  { key: "dashboard", label: "Dashboard" },
  { key: "env", label: "Config" },
  { key: "identity", label: "Identity" },
  { key: "skills", label: "Skills" },
  { key: "tools", label: "Tools" },
  { key: "logs", label: "Logs" },
  { key: "ops", label: "Backups" },
];

class AgentManagerTui {
  private agents: AgentInfo[] = [];
  private selectedAgentIndex = 0;
  private currentView: View = "dashboard";
  private fileIndexByView: Record<View, number> = {
    dashboard: 0,
    env: 0,
    identity: 0,
    skills: 0,
    tools: 0,
    logs: 0,
    ops: 0,
  };
  private currentFilePath: string | null = null;
  private loadedFileText = "";
  private currentFileReadOnly = false;
  private unsaved = false;
  private message = "Ready";
  private logs: string[] = [];
  private opsOutput: string[] = ["Backup tools ready."];
  private statusTimer: ReturnType<typeof setInterval> | null = null;
  private logProcess: ChildProcessWithoutNullStreams | null = null;
  private promptState: PromptState | null = null;
  private envModalState: EnvModalState | null = null;
  private focusMode: "agents" | "files" | "editor" = "agents";

  private renderer!: Awaited<ReturnType<typeof createCliRenderer>>;
  private rootLayout!: BoxRenderable;
  private headerText!: TextRenderable;
  private footerText!: TextRenderable;
  private agentsText!: TextRenderable;
  private tabsText!: TextRenderable;
  private dashboardContainer!: BoxRenderable;
  private dashboardText!: TextRenderable;
  private fileListText!: TextRenderable;
  private editor!: TextareaRenderable;
  private editorContainer!: BoxRenderable;
  private splitContainer!: BoxRenderable;
  private logsContainer!: BoxRenderable;
  private logsText!: TextRenderable;
  private opsContainer!: BoxRenderable;
  private opsText!: TextRenderable;
  private promptOverlay!: BoxRenderable;
  private promptTitleText!: TextRenderable;
  private promptInput!: InputRenderable;
  private envModalOverlay!: BoxRenderable;
  private envModalTitle!: TextRenderable;
  private envModalVars!: TextRenderable;
  private envModalKeyInput!: InputRenderable;
  private envModalValueInput!: InputRenderable;

  async start(): Promise<void> {
    this.renderer = await createCliRenderer({
      useAlternateScreen: true,
      useMouse: true,
      autoFocus: true,
      targetFps: 30,
      maxFps: 60,
      exitOnCtrlC: false,
    });
    this.renderer.setTerminalTitle("ZeroClaw Agent Manager");

    this.createUi();
    this.refreshAgents();
    this.bindKeys();
    this.renderAll();

    this.statusTimer = setInterval(() => {
      this.refreshAgentsStatusOnly();
      this.renderAll();
    }, 5000);

    this.renderer.start();
  }

  private createUi(): void {
    this.rootLayout = new BoxRenderable(this.renderer, {
      width: "100%",
      height: "100%",
      flexDirection: "column",
      backgroundColor: THEME.bg,
      paddingX: TAB_PAD_X,
      paddingY: TAB_PAD_Y,
    });

    const header = new BoxRenderable(this.renderer, {
      height: 3,
      backgroundColor: THEME.panel,
      paddingX: TAB_PAD_X,
      justifyContent: "center",
    });
    this.headerText = new TextRenderable(this.renderer, {
      content: "",
      fg: THEME.text,
      attributes: 1,
    });
    header.add(this.headerText);

    const body = new BoxRenderable(this.renderer, {
      flexGrow: 1,
      flexDirection: "row",
      marginTop: 1,
    });

    const sidebar = new BoxRenderable(this.renderer, {
      width: 34,
      backgroundColor: THEME.panelAlt,
      paddingX: TAB_PAD_X,
      paddingY: TAB_PAD_Y,
    });
    this.agentsText = new TextRenderable(this.renderer, {
      content: "",
      fg: THEME.textMuted,
    });
    sidebar.add(this.agentsText);

    const contentColumn = new BoxRenderable(this.renderer, {
      flexGrow: 1,
      flexDirection: "column",
      marginLeft: TAB_PAD_X,
    });

    const tabs = new BoxRenderable(this.renderer, {
      height: 3,
      backgroundColor: THEME.panel,
      paddingX: TAB_PAD_X,
      justifyContent: "center",
    });
    this.tabsText = new TextRenderable(this.renderer, {
      content: "",
      fg: THEME.textMuted,
    });
    tabs.add(this.tabsText);

    const content = new BoxRenderable(this.renderer, {
      flexGrow: 1,
      backgroundColor: THEME.panelAlt,
      marginTop: 1,
      flexDirection: "column",
      paddingX: 0,
      paddingY: 0,
    });

    this.dashboardContainer = new BoxRenderable(this.renderer, {
      width: "100%",
      height: "100%",
      backgroundColor: THEME.panelAlt,
      paddingX: TAB_PAD_X,
      paddingY: TAB_PAD_Y,
    });

    this.dashboardText = new TextRenderable(this.renderer, {
      content: "",
      fg: THEME.text,
      width: "100%",
      height: "100%",
    });

    this.splitContainer = new BoxRenderable(this.renderer, {
      width: "100%",
      height: "100%",
      flexDirection: "row",
    });

    const fileListContainer = new BoxRenderable(this.renderer, {
      width: 38,
      backgroundColor: THEME.panelAlt,
      paddingX: TAB_PAD_X,
      paddingY: TAB_PAD_Y,
    });
    this.fileListText = new TextRenderable(this.renderer, {
      content: "",
      fg: THEME.textMuted,
    });
    fileListContainer.add(this.fileListText);

    this.editorContainer = new BoxRenderable(this.renderer, {
      flexGrow: 1,
      backgroundColor: THEME.panelAlt,
      marginLeft: TAB_PAD_X,
      paddingX: TAB_PAD_X,
      paddingY: TAB_PAD_Y,
      flexDirection: "column",
    });
    this.editor = new TextareaRenderable(this.renderer, {
      flexGrow: 1,
      width: "100%",
      height: "100%",
      backgroundColor: THEME.panelAlt,
      textColor: "#e2ecff",
      focusedBackgroundColor: THEME.panelAlt,
      focusedTextColor: "#f0f6ff",
      placeholder: "No file selected",
      wrapMode: "none",
      onContentChange: () => {
        if (this.currentFilePath !== null) {
          if (this.currentFileReadOnly) {
            this.unsaved = false;
          } else {
            this.unsaved = this.editor.plainText !== this.loadedFileText;
          }
          this.renderAll();
        }
      },
    });
    this.editorContainer.add(this.editor);

    this.splitContainer.add(fileListContainer);
    this.splitContainer.add(this.editorContainer);

    this.logsContainer = new ScrollBoxRenderable(this.renderer, {
      width: "100%",
      height: "100%",
      backgroundColor: THEME.panelAlt,
      stickyScroll: true,
      stickyStart: "bottom",
      paddingX: 0,
      paddingY: 0,
      viewportOptions: {
        paddingX: TAB_PAD_X,
      },
      contentOptions: {
        paddingY: TAB_PAD_Y,
      },
    });
    this.logsText = new TextRenderable(this.renderer, {
      content: "",
      fg: THEME.text,
    });
    this.logsContainer.add(this.logsText);

    this.opsContainer = new BoxRenderable(this.renderer, {
      width: "100%",
      height: "100%",
      backgroundColor: THEME.panelAlt,
      paddingX: TAB_PAD_X,
      paddingY: TAB_PAD_Y,
    });
    this.opsText = new TextRenderable(this.renderer, {
      content: "",
      fg: THEME.text,
      width: "100%",
      height: "100%",
    });
    this.opsContainer.add(this.opsText);

    this.dashboardContainer.add(this.dashboardText);
    content.add(this.dashboardContainer);
    content.add(this.splitContainer);
    content.add(this.logsContainer);
    content.add(this.opsContainer);

    contentColumn.add(tabs);
    contentColumn.add(content);

    body.add(sidebar);
    body.add(contentColumn);

    const footer = new BoxRenderable(this.renderer, {
      height: 5,
      backgroundColor: THEME.panel,
      paddingX: TAB_PAD_X,
      paddingY: TAB_PAD_Y,
      marginTop: 1,
    });
    this.footerText = new TextRenderable(this.renderer, {
      content: "",
      fg: THEME.text,
    });
    footer.add(this.footerText);

    this.promptOverlay = new BoxRenderable(this.renderer, {
      position: "absolute",
      top: "35%",
      left: "20%",
      width: "60%",
      height: 8,
      border: true,
      borderColor: THEME.accent,
      backgroundColor: THEME.promptBg,
      zIndex: 100,
      paddingX: 1,
      paddingY: 1,
      flexDirection: "column",
      visible: false,
    });
    this.promptTitleText = new TextRenderable(this.renderer, {
      content: "",
      fg: THEME.text,
      attributes: 1,
    });
    this.promptInput = new InputRenderable(this.renderer, {
      marginTop: 1,
      width: "100%",
      backgroundColor: THEME.editorBg,
      textColor: "#f0f6ff",
      focusedBackgroundColor: THEME.editorFocusBg,
      focusedTextColor: "#f0f6ff",
      placeholder: "",
      onSubmit: () => {
        this.submitPrompt();
      },
    });
    const promptHint = new TextRenderable(this.renderer, {
      marginTop: 1,
      content: "Enter to confirm, Esc to cancel",
      fg: THEME.text,
    });
    this.promptOverlay.add(this.promptTitleText);
    this.promptOverlay.add(this.promptInput);
    this.promptOverlay.add(promptHint);

    this.envModalOverlay = new BoxRenderable(this.renderer, {
      position: "absolute",
      top: "22%",
      left: "18%",
      width: "64%",
      height: 15,
      border: true,
      borderColor: THEME.success,
      backgroundColor: THEME.envModalBg,
      zIndex: 101,
      paddingX: 1,
      paddingY: 1,
      flexDirection: "column",
      visible: false,
    });
    this.envModalTitle = new TextRenderable(this.renderer, {
      content: "Edit environment variable",
      fg: "#d7ffe9",
      attributes: 1,
    });
    this.envModalVars = new TextRenderable(this.renderer, {
      marginTop: 1,
      content: "",
      fg: "#d4f5e6",
    });
    this.envModalKeyInput = new InputRenderable(this.renderer, {
      marginTop: 1,
      width: "100%",
      placeholder: "KEY (e.g. ZEROCLAW_MODEL)",
      backgroundColor: "#123025",
      textColor: "#e9fff6",
      focusedBackgroundColor: "#184233",
      focusedTextColor: "#e9fff6",
      onSubmit: () => {
        this.moveEnvModalFocus("value");
      },
    });
    this.envModalValueInput = new InputRenderable(this.renderer, {
      marginTop: 1,
      width: "100%",
      placeholder: "VALUE",
      backgroundColor: "#123025",
      textColor: "#e9fff6",
      focusedBackgroundColor: "#184233",
      focusedTextColor: "#e9fff6",
      onSubmit: () => {
        this.applyEnvModal();
      },
    });
    const envModalHint = new TextRenderable(this.renderer, {
      marginTop: 1,
      content: "Tab switch field | Enter apply | Ctrl+d delete key | Esc cancel",
      fg: "#d4f5e6",
    });
    this.envModalOverlay.add(this.envModalTitle);
    this.envModalOverlay.add(this.envModalVars);
    this.envModalOverlay.add(this.envModalKeyInput);
    this.envModalOverlay.add(this.envModalValueInput);
    this.envModalOverlay.add(envModalHint);

    this.rootLayout.add(header);
    this.rootLayout.add(body);
    this.rootLayout.add(footer);
    this.rootLayout.add(this.promptOverlay);
    this.rootLayout.add(this.envModalOverlay);

    this.renderer.root.add(this.rootLayout);
  }

  private bindKeys(): void {
    this.renderer.keyInput.on("keypress", (key) => {
      if (this.envModalState !== null) {
        if (key.name === "escape") {
          this.closeEnvModal();
          key.preventDefault();
          return;
        }
        if (key.name === "tab") {
          this.moveEnvModalFocus(this.envModalState.focus === "key" ? "value" : "key");
          key.preventDefault();
          return;
        }
        if (key.ctrl && key.name === "d") {
          this.deleteEnvModalKey();
          key.preventDefault();
          return;
        }
        return;
      }

      if (this.promptState !== null) {
        if (key.name === "escape") {
          this.closePrompt();
          key.preventDefault();
        }
        return;
      }

      if ((key.ctrl && key.name === "c") || key.name === "q") {
        this.shutdown();
        key.preventDefault();
        return;
      }

      if (key.ctrl && key.name === "s") {
        this.saveCurrentFile();
        key.preventDefault();
        return;
      }

      if (key.name === "tab") {
        this.cycleFocus();
        key.preventDefault();
        return;
      }

      if (key.name === "r") {
        if (this.currentView === "ops") {
          this.runOpsListBackups();
          key.preventDefault();
          return;
        }
        this.refreshAgents();
        this.renderAll();
        key.preventDefault();
        return;
      }

      if (key.name === "e" && this.currentView === "env") {
        this.openEnvModal();
        key.preventDefault();
        return;
      }

      if (this.currentView === "tools") {
        if (key.name === "i") {
          this.promptInstallToolFromCatalog();
          key.preventDefault();
          return;
        }
        if (key.name === "p") {
          this.promptAddAptPackages();
          key.preventDefault();
          return;
        }
        if (key.name === "b") {
          this.promptAddBunPackages();
          key.preventDefault();
          return;
        }
      }

      if (this.currentView === "ops") {
        if (key.name === "b") {
          this.runOpsBackupData();
          key.preventDefault();
          return;
        }
        if (key.name === "c") {
          this.runOpsBackupConfig();
          key.preventDefault();
          return;
        }
        if (key.name === "u") {
          this.runOpsSyncToMinio();
          key.preventDefault();
          return;
        }
        if (key.name === "i") {
          this.runOpsSyncFromMinio();
          key.preventDefault();
          return;
        }
        if (key.name === "v") {
          this.runOpsLitestreamStatus();
          key.preventDefault();
          return;
        }
        if (key.name === "p") {
          this.runOpsLitestreamSnapshot();
          key.preventDefault();
          return;
        }
        if (key.name === "g") {
          this.runOpsLitestreamLogs();
          key.preventDefault();
          return;
        }
        if (key.name === "o") {
          this.promptOpsRestoreBackup();
          key.preventDefault();
          return;
        }
        if (key.name === "y") {
          this.promptOpsRestoreLitestream();
          key.preventDefault();
          return;
        }
      }

      if (key.name === "a") {
        this.openPrompt({
          title: "Create new agent",
          placeholder: "agent-name",
          handler: (value) => {
            this.runAgentCommand(["create", value], `Created agent ${value}`);
          },
        });
        key.preventDefault();
        return;
      }

      if (key.shift && key.name === "c") {
        this.duplicateSelectedAgent();
        key.preventDefault();
        return;
      }

      if (key.shift && key.name === "d") {
        const agent = this.getSelectedAgent();
        if (agent !== null) {
          this.openPrompt({
            title: `Remove agent ${agent.name} safely (type: remove ${agent.name})`,
            placeholder: `remove ${agent.name}`,
            handler: (value) => {
              if (value !== `remove ${agent.name}`) {
                this.message = "Removal aborted: name mismatch";
                this.renderAll();
                return;
              }
              this.removeAgentDirectory(agent.name);
            },
          });
        }
        key.preventDefault();
        return;
      }

      if (key.name === "s") {
        this.runSelectedAgentCommand("start");
        key.preventDefault();
        return;
      }
      if (key.name === "t") {
        this.runSelectedAgentCommand("stop");
        key.preventDefault();
        return;
      }
      if (key.shift && key.name === "r") {
        this.runSelectedAgentCommand("restart");
        key.preventDefault();
        return;
      }

      if (key.name === "n") {
        this.newFileForCurrentView();
        key.preventDefault();
        return;
      }

      if (key.name === "x") {
        this.deleteCurrentFileIfAllowed();
        key.preventDefault();
        return;
      }

      if (this.currentView === "skills" && key.name === "m") {
        this.renameSelectedSkillFile();
        key.preventDefault();
        return;
      }

      if (this.currentView === "skills" && key.name === "y") {
        this.copySelectedSkillFile();
        key.preventDefault();
        return;
      }

      if (key.name === "c" && this.currentView === "logs") {
        this.logs = [];
        this.renderAll();
        key.preventDefault();
        return;
      }

      if (["1", "2", "3", "4", "5", "6", "7"].includes(key.name)) {
        const idx = Number.parseInt(key.name, 10) - 1;
        if (idx >= 0 && idx < VIEWS.length) {
          this.switchView(VIEWS[idx].key);
        }
        key.preventDefault();
        return;
      }

      if (key.name === "left") {
        this.moveView(-1);
        key.preventDefault();
        return;
      }
      if (key.name === "right") {
        this.moveView(1);
        key.preventDefault();
        return;
      }

      if (this.focusMode === "agents") {
        if (key.name === "up" || key.name === "k") {
          this.moveAgentSelection(-1);
          key.preventDefault();
          return;
        }
        if (key.name === "down" || key.name === "j") {
          this.moveAgentSelection(1);
          key.preventDefault();
          return;
        }
      }

      if (this.focusMode === "files") {
        if (key.name === "up" || key.name === "k") {
          this.moveFileSelection(-1);
          key.preventDefault();
          return;
        }
        if (key.name === "down" || key.name === "j") {
          this.moveFileSelection(1);
          key.preventDefault();
          return;
        }
        if (key.name === "return" || key.name === "enter") {
          this.loadCurrentFile();
          key.preventDefault();
        }
      }
    });
  }

  private shutdown(): void {
    if (this.statusTimer !== null) {
      clearInterval(this.statusTimer);
      this.statusTimer = null;
    }
    this.stopLogStream();
    this.renderer.destroy();
  }

  private refreshAgents(): void {
    this.agents = this.discoverAgents();
    if (this.selectedAgentIndex >= this.agents.length) {
      this.selectedAgentIndex = Math.max(0, this.agents.length - 1);
    }
    this.loadCurrentFile();
  }

  private refreshAgentsStatusOnly(): void {
    const running = this.getRunningContainerNames();
    this.agents = this.agents.map((agent) => ({
      ...agent,
      status: this.resolveStatusFromContainers(agent.name, running),
    }));
  }

  private discoverAgents(): AgentInfo[] {
    if (!existsSync(AGENTS_DIR)) {
      this.message = `Agents directory not found: ${AGENTS_DIR}`;
      return [];
    }

    const running = this.getRunningContainerNames();
    const dirs = readdirSync(AGENTS_DIR, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
      .filter((name) => !name.startsWith("."))
      .filter((name) => name !== "templates")
      .map((name) => {
        const dir = join(AGENTS_DIR, name);
        return {
          name,
          dir,
          envPath: join(dir, ".env"),
          status: this.resolveStatusFromContainers(name, running),
        } satisfies AgentInfo;
      })
      .filter((agent) => existsSync(agent.envPath))
      .sort((a, b) => a.name.localeCompare(b.name));

    return dirs;
  }

  private getRunningContainerNames(): Set<string> {
    const out = spawnSync("docker", ["ps", "--format", "{{.Names}}"], {
      cwd: ROOT_DIR,
      encoding: "utf-8",
    });
    if (out.status !== 0) {
      return new Set<string>();
    }
    return new Set(
      out.stdout
        .split("\n")
        .map((line) => line.trim())
        .filter((line) => line.length > 0),
    );
  }

  private resolveStatusFromContainers(agentName: string, containerNames: Set<string>): AgentStatus {
    for (const name of containerNames) {
      if (name.includes(`zeroclaw-${agentName}`)) {
        return "running";
      }
    }
    return "stopped";
  }

  private renderAll(): void {
    this.headerText.content = this.renderHeader();
    this.agentsText.content = this.renderAgentsList();
    this.tabsText.content = this.renderTabs();
    this.dashboardText.content = this.renderDashboard();
    this.fileListText.content = this.renderFileList();
    this.logsText.content = this.logs.length === 0 ? "No logs yet." : this.logs.join("\n");
    this.opsText.content = this.renderOps();
    this.footerText.content = this.renderFooter();

    this.dashboardContainer.visible = this.currentView === "dashboard";
    this.dashboardText.visible = this.currentView === "dashboard";
    this.splitContainer.visible = ["env", "identity", "skills", "tools"].includes(this.currentView);
    this.logsContainer.visible = this.currentView === "logs";
    this.opsContainer.visible = this.currentView === "ops";

    this.editorContainer.title = this.editorTitle();
    this.promptOverlay.visible = this.promptState !== null;
    this.envModalOverlay.visible = this.envModalState !== null;

    if (
      this.focusMode === "editor" &&
      this.currentFilePath !== null &&
      this.promptState === null &&
      this.envModalState === null
    ) {
      this.editor.focus();
    } else {
      this.editor.blur();
    }

    if (this.envModalState !== null) {
      if (this.envModalState.focus === "key") {
        this.envModalKeyInput.focus();
        this.envModalValueInput.blur();
      } else {
        this.envModalValueInput.focus();
        this.envModalKeyInput.blur();
      }
    } else {
      this.envModalKeyInput.blur();
      this.envModalValueInput.blur();
    }

    this.renderer.requestRender();
  }

  private renderHeader(): string {
    const agent = this.getSelectedAgent();
    const selected = agent === null ? "none" : `${agent.name} | ${agent.status.toUpperCase()}`;
    return `ZeroClaw Agent Manager  |  Selected: ${selected}  |  Workspace: ${relative(ROOT_DIR, AGENTS_DIR)}`;
  }

  private renderAgentsList(): string {
    if (this.agents.length === 0) {
      return "No agents found.\nPress 'a' to create one.";
    }

    const lines: string[] = [];
    lines.push(this.focusMode === "agents" ? "[ACTIVE] AGENTS" : "AGENTS");
    lines.push("");
    this.agents.forEach((agent, index) => {
      const marker = index === this.selectedAgentIndex ? ">" : " ";
      const status = agent.status === "running" ? "RUNNING" : agent.status === "stopped" ? "STOPPED" : "UNKNOWN";
      lines.push(`${marker} ${agent.name.padEnd(18)} ${status}`);
    });
    return lines.join("\n");
  }

  private renderTabs(): string {
    const chunks = VIEWS.map((view, index) => {
      const active = view.key === this.currentView;
      const label = `${index + 1}:${view.label}`;
      return active ? `[ ${label} ]` : `  ${label}  `;
    });
    return chunks.join("   ");
  }

  private renderDashboard(): string {
    const agent = this.getSelectedAgent();
    if (agent === null) {
      return "No agent selected.";
    }

    const envText = this.safeRead(agent.envPath);
    const envMap = this.parseEnv(envText);
    const envErrors = this.validateEnv(envText);
    const identityFiles = this.getIdentityFiles(agent);
    const skillFiles = this.getSkillFiles(agent);
    const toolFiles = this.getToolFiles(agent);

    const lines: string[] = [];
    lines.push(`Overview for ${agent.name}`);
    lines.push(`Status      : ${agent.status}`);
    lines.push(`Directory   : ${relative(ROOT_DIR, agent.dir)}`);
    lines.push("");
    lines.push("Config Snapshot");
    lines.push(`  AGENT_ROLE               ${envMap.AGENT_ROLE ?? "(unset)"}`);
    lines.push(`  ZEROCLAW_MODEL           ${envMap.ZEROCLAW_MODEL ?? "(unset)"}`);
    lines.push(`  ZEROCLAW_TEMPERATURE     ${envMap.ZEROCLAW_TEMPERATURE ?? "(unset)"}`);
    lines.push(`  ZEROCLAW_MEMORY_BACKEND  ${envMap.ZEROCLAW_MEMORY_BACKEND ?? "(unset)"}`);
    lines.push(`  ZEROCLAW_SHELL_ENABLED   ${envMap.ZEROCLAW_SHELL_ENABLED ?? "(unset)"}`);
    lines.push(`  ZEROCLAW_FILE_ENABLED    ${envMap.ZEROCLAW_FILE_ENABLED ?? "(unset)"}`);
    lines.push(`  ZEROCLAW_BROWSER_ENABLED ${envMap.ZEROCLAW_BROWSER_ENABLED ?? "(unset)"}`);
    lines.push("");
    lines.push("Content Summary");
    lines.push(`  Identity docs  ${identityFiles.length}`);
    lines.push(`  Skill files    ${skillFiles.length}`);
    lines.push(`  Tool files     ${toolFiles.length}`);
    if (envErrors.length > 0) {
      lines.push("");
      lines.push("Env Validation");
      for (const err of envErrors.slice(0, 6)) {
        lines.push(`  - ${err}`);
      }
      if (envErrors.length > 6) {
        lines.push(`  - ... ${envErrors.length - 6} more`);
      }
    }
    return lines.join("\n");
  }

  private renderFileList(): string {
    if (!["env", "identity", "skills", "tools"].includes(this.currentView)) {
      return "";
    }
    const files = this.getFilesForCurrentView();
    if (files.length === 0) {
      return this.focusMode === "files"
        ? "[ACTIVE] FILES\n\nNo files in this view.\nPress n to create one."
        : "FILES\n\nNo files in this view.\nPress n to create one.";
    }

    const selected = this.getCurrentFileIndex();
    const lines: string[] = [];
    lines.push(this.focusMode === "files" ? "[ACTIVE] FILES" : "FILES");
    lines.push("");
    for (let i = 0; i < files.length; i++) {
      const marker = i === selected ? ">" : " ";
      const file = files[i];
      lines.push(`${marker} ${relative(this.getSelectedAgent()!.dir, file)}`);
    }
    return lines.join("\n");
  }

  private renderOps(): string {
    const agent = this.getSelectedAgent();
    if (agent === null) {
      return "No agent selected.";
    }

    const lines: string[] = [];
    lines.push(`Backup Operations for ${agent.name}`);
    lines.push("");
    lines.push("Actions");
    lines.push("- b: Backup memory/data volume");
    lines.push("- c: Backup agent config directory");
    lines.push("- r: List local backups");
    lines.push("- u: Upload latest backup to MinIO");
    lines.push("- i: Download latest backup from MinIO");
    lines.push("- o: Restore from local backup file");
    lines.push("- v: Litestream status");
    lines.push("- p: Litestream snapshot");
    lines.push("- g: Litestream logs");
    lines.push("- y: Litestream restore (timestamp/latest)");
    lines.push("");
    lines.push("Recent Output");

    const recent = this.opsOutput.slice(-24);
    if (recent.length === 0) {
      lines.push("(no output yet)");
    } else {
      lines.push(...recent);
    }
    return lines.join("\n");
  }

  private renderFooter(): string {
    const envErrors = this.currentView === "env" && this.currentFilePath !== null
      ? this.validateEnv(this.editor.plainText).length
      : 0;
    const envPart = this.currentView === "env" ? ` | env-errors:${envErrors}` : "";
    const unsavedPart = this.unsaved ? " | unsaved" : "";
    const readOnlyPart = this.currentFileReadOnly ? " | read-only" : "";
    const focusPart = `focus:${this.focusMode}`;
    const envModalHint = this.currentView === "env" ? " | e env-modal" : "";
    const skillsHint = this.currentView === "skills" ? " | skills:m rename y copy" : "";
    const toolsHint = this.currentView === "tools" ? " | tools:i catalog p apt b bun" : "";
    const opsHint = this.currentView === "ops" ? " | ops:b/c/r/u/i/o/v/p/g/y" : "";
    return [
      `Status: ${this.message}${unsavedPart}${readOnlyPart}${envPart}`,
      `Global: q quit | Tab focus | 1-7 views | a create | Shift+c duplicate | Shift+d safe-remove | s start | t stop | Shift+r restart`,
      `File: Ctrl+s save | n new | x delete | r refresh/list | ${focusPart}${envModalHint}${skillsHint}${toolsHint}${opsHint}`,
    ].join("\n");
  }

  private editorTitle(): string {
    const pathLabel = this.currentFilePath === null
      ? "Editor"
      : relative(ROOT_DIR, this.currentFilePath);
    const dirty = this.unsaved ? " *" : "";
    const focus = this.focusMode === "editor" ? " [ACTIVE]" : "";
    return `${pathLabel}${dirty}${focus}`;
  }

  private getSelectedAgent(): AgentInfo | null {
    if (this.agents.length === 0) {
      return null;
    }
    return this.agents[this.selectedAgentIndex] ?? null;
  }

  private moveAgentSelection(delta: number): void {
    if (this.agents.length === 0) {
      return;
    }
    const next = Math.max(0, Math.min(this.agents.length - 1, this.selectedAgentIndex + delta));
    if (next === this.selectedAgentIndex) {
      return;
    }
    this.guardUnsaved(() => {
      this.selectedAgentIndex = next;
      this.message = `Selected agent ${this.agents[next].name}`;
      this.loadCurrentFile();
      this.restartLogStreamIfNeeded();
      this.renderAll();
    });
  }

  private moveView(delta: number): void {
    const idx = VIEWS.findIndex((v) => v.key === this.currentView);
    const next = idx + delta;
    if (next < 0 || next >= VIEWS.length) {
      return;
    }
    this.switchView(VIEWS[next].key);
  }

  private switchView(view: View): void {
    if (view === this.currentView) {
      return;
    }
    this.guardUnsaved(() => {
      this.currentView = view;
      this.fileIndexByView[view] = Math.max(0, this.fileIndexByView[view] ?? 0);

      if (view === "dashboard" || view === "logs" || view === "ops") {
        this.focusMode = "agents";
      } else if (this.focusMode === "editor") {
        this.focusMode = "files";
      }

      if (view === "logs") {
        this.startLogStream();
      } else {
        this.stopLogStream();
      }

      this.loadCurrentFile();
      this.renderAll();
    });
  }

  private cycleFocus(): void {
    if (this.currentView === "dashboard" || this.currentView === "logs" || this.currentView === "ops") {
      this.focusMode = "agents";
      this.renderAll();
      return;
    }
    if (this.focusMode === "agents") {
      this.focusMode = "files";
    } else if (this.focusMode === "files") {
      this.focusMode = "editor";
    } else {
      this.focusMode = "agents";
    }
    this.renderAll();
  }

  private getCurrentFileIndex(): number {
    return this.fileIndexByView[this.currentView] ?? 0;
  }

  private setCurrentFileIndex(index: number): void {
    this.fileIndexByView[this.currentView] = index;
  }

  private moveFileSelection(delta: number): void {
    const files = this.getFilesForCurrentView();
    if (files.length === 0) {
      return;
    }
    const current = this.getCurrentFileIndex();
    const next = Math.max(0, Math.min(files.length - 1, current + delta));
    if (next === current) {
      return;
    }
    this.guardUnsaved(() => {
      this.setCurrentFileIndex(next);
      this.loadCurrentFile();
      this.renderAll();
    });
  }

  private loadCurrentFile(): void {
    const files = this.getFilesForCurrentView();
    if (files.length === 0) {
      this.currentFilePath = null;
      this.loadedFileText = "";
      this.currentFileReadOnly = false;
      this.unsaved = false;
      this.editor.setText("");
      return;
    }
    const index = Math.min(this.getCurrentFileIndex(), files.length - 1);
    this.setCurrentFileIndex(index);
    const filePath = files[index];
    this.currentFilePath = filePath;
    const loaded = this.loadEditorContentForPath(filePath);
    this.loadedFileText = loaded.content;
    this.currentFileReadOnly = loaded.readOnly;
    this.editor.setText(this.loadedFileText);
    this.unsaved = false;
  }

  private saveCurrentFile(): void {
    if (this.currentFilePath === null) {
      this.message = "No file selected";
      this.renderAll();
      return;
    }

    if (this.currentFileReadOnly) {
      this.message = "Selected file is read-only in TUI";
      this.renderAll();
      return;
    }

    const content = this.editor.plainText;
    writeFileSync(this.currentFilePath, content, "utf-8");
    this.loadedFileText = content;
    this.unsaved = false;
    this.message = `Saved ${relative(ROOT_DIR, this.currentFilePath)}`;
    this.refreshAgentsStatusOnly();
    this.renderAll();
  }

  private getFilesForCurrentView(): string[] {
    const agent = this.getSelectedAgent();
    if (agent === null) {
      return [];
    }

    switch (this.currentView) {
      case "env":
        return [agent.envPath];
      case "identity":
        return this.getIdentityFiles(agent);
      case "skills":
        return this.getSkillFiles(agent);
      case "tools":
        return this.getToolFiles(agent);
      default:
        return [];
    }
  }

  private getIdentityFiles(agent: AgentInfo): string[] {
    return readdirSync(agent.dir, { withFileTypes: true })
      .filter((entry) => entry.isFile())
      .map((entry) => join(agent.dir, entry.name))
      .filter((fullPath) => fullPath.endsWith(".md"))
      .sort((a, b) => a.localeCompare(b));
  }

  private getSkillFiles(agent: AgentInfo): string[] {
    return this.listFilesRecursive(join(agent.dir, "skills"));
  }

  private getToolFiles(agent: AgentInfo): string[] {
    const files: string[] = [];
    const toolsToml = this.getToolsTomlPath(agent);
    if (existsSync(toolsToml)) {
      files.push(toolsToml);
    }
    const localToolFiles = this.listFilesRecursive(join(agent.dir, "tools"));
    files.push(...localToolFiles);
    return files;
  }

  private getToolsTomlPath(agent: AgentInfo): string {
    return join(agent.dir, "tools.toml");
  }

  private ensureToolsToml(agent: AgentInfo): string {
    const toolsToml = this.getToolsTomlPath(agent);
    if (!existsSync(toolsToml)) {
      const initial = [
        `# Tool declarations for ${agent.name} image builds.`,
        "# The resolver copies entries into .build-tools before docker build.",
        "",
      ].join("\n");
      writeFileSync(toolsToml, initial, "utf-8");
    }
    return toolsToml;
  }

  private parseTomlStringArray(content: string, section: "apt" | "bun"): string[] {
    const sectionMatch = content.match(new RegExp(`\\[${section}\\][\\s\\S]*?(?=\\n\\[[^\\]]+\\]|$)`));
    if (sectionMatch === null) {
      return [];
    }
    const packagesMatch = sectionMatch[0].match(/packages\s*=\s*\[([^\]]*)\]/);
    if (packagesMatch === null) {
      return [];
    }
    const values: string[] = [];
    const regex = /"([^"]+)"/g;
    let m: RegExpExecArray | null = regex.exec(packagesMatch[1]);
    while (m !== null) {
      const value = m[1].trim();
      if (value.length > 0) {
        values.push(value);
      }
      m = regex.exec(packagesMatch[1]);
    }
    return values;
  }

  private upsertTomlStringArray(content: string, section: "apt" | "bun", values: string[]): string {
    const unique = Array.from(new Set(values.map((v) => v.trim()).filter((v) => v.length > 0))).sort((a, b) =>
      a.localeCompare(b)
    );
    const block = `[${section}]\npackages = [${unique.map((v) => `"${v}"`).join(", ")}]`;
    const sectionRegex = new RegExp(`\\[${section}\\][\\s\\S]*?(?=\\n\\[[^\\]]+\\]|$)`);
    if (sectionRegex.test(content)) {
      return content.replace(sectionRegex, block);
    }
    const prefix = content.trimEnd();
    return `${prefix.length > 0 ? `${prefix}\n\n` : ""}${block}\n`;
  }

  private hasToolName(content: string, toolName: string): boolean {
    const escaped = toolName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const re = new RegExp(`\\[\\[tool\\]\\][\\s\\S]*?name\\s*=\\s*"${escaped}"`, "m");
    return re.test(content);
  }

  private listFilesRecursive(baseDir: string): string[] {
    if (!existsSync(baseDir)) {
      return [];
    }
    const out: string[] = [];
    const walk = (dir: string): void => {
      const entries = readdirSync(dir, { withFileTypes: true });
      for (const entry of entries) {
        if (entry.name.startsWith(".")) {
          continue;
        }
        const full = join(dir, entry.name);
        if (entry.isDirectory()) {
          walk(full);
          continue;
        }
        out.push(full);
      }
    };
    walk(baseDir);
    out.sort((a, b) => a.localeCompare(b));
    return out;
  }

  private parseEnv(content: string): Record<string, string> {
    const out: Record<string, string> = {};
    const lines = content.split(/\r?\n/);
    for (const line of lines) {
      const trimmed = line.trim();
      if (trimmed.length === 0 || trimmed.startsWith("#") || !trimmed.includes("=")) {
        continue;
      }
      const idx = trimmed.indexOf("=");
      const key = trimmed.slice(0, idx).trim();
      const value = trimmed.slice(idx + 1).trim();
      out[key] = value;
    }
    return out;
  }

  private validateEnv(content: string): string[] {
    const errors: string[] = [];
    const keys = new Set<string>();
    const lines = content.split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      const raw = lines[i];
      const line = raw.trim();
      if (line.length === 0 || line.startsWith("#")) {
        continue;
      }
      if (!line.includes("=")) {
        errors.push(`line ${i + 1}: missing '='`);
        continue;
      }
      const idx = line.indexOf("=");
      const key = line.slice(0, idx).trim();
      if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) {
        errors.push(`line ${i + 1}: invalid key '${key}'`);
      }
      if (keys.has(key)) {
        errors.push(`line ${i + 1}: duplicate key '${key}'`);
      }
      keys.add(key);
    }
    return errors;
  }

  private openEnvModal(): void {
    if (this.currentView !== "env") {
      return;
    }
    const envMap = this.parseEnv(this.editor.plainText);
    const keys = Object.keys(envMap).sort((a, b) => a.localeCompare(b));
    const preview = keys.slice(0, 10);
    const previewText = preview.length === 0 ? "(no variables yet)" : preview.join(", ");
    this.envModalVars.content = `Existing keys: ${previewText}`;
    this.envModalKeyInput.value = "";
    this.envModalValueInput.value = "";
    this.envModalState = { focus: "key" };
    this.renderAll();
  }

  private closeEnvModal(): void {
    this.envModalState = null;
    this.message = "Env modal closed";
    this.renderAll();
  }

  private moveEnvModalFocus(next: "key" | "value"): void {
    if (this.envModalState === null) {
      return;
    }
    if (next === "value") {
      const key = this.envModalKeyInput.value.trim();
      if (key.length > 0) {
        const envMap = this.parseEnv(this.editor.plainText);
        if (Object.hasOwn(envMap, key)) {
          this.envModalValueInput.value = envMap[key] ?? "";
        }
      }
    }
    this.envModalState.focus = next;
    this.renderAll();
  }

  private applyEnvModal(): void {
    if (this.envModalState === null) {
      return;
    }
    const key = this.envModalKeyInput.value.trim();
    const value = this.envModalValueInput.value;
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) {
      this.message = `Invalid env key: ${key}`;
      this.renderAll();
      return;
    }

    const updated = this.upsertEnvVariable(this.editor.plainText, key, value);
    this.editor.setText(updated);
    this.unsaved = updated !== this.loadedFileText;
    this.envModalState = null;
    this.message = `Set ${key} in env buffer`;
    this.renderAll();
  }

  private deleteEnvModalKey(): void {
    if (this.envModalState === null) {
      return;
    }
    const key = this.envModalKeyInput.value.trim();
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) {
      this.message = "Enter a valid key to delete";
      this.renderAll();
      return;
    }
    const updated = this.deleteEnvVariable(this.editor.plainText, key);
    this.editor.setText(updated);
    this.unsaved = updated !== this.loadedFileText;
    this.envModalState = null;
    this.message = `Removed ${key} from env buffer`;
    this.renderAll();
  }

  private upsertEnvVariable(content: string, key: string, value: string): string {
    const lines = content.split(/\r?\n/);
    const keyPattern = new RegExp(`^\\s*${this.escapeRegex(key)}\\s*=`);
    const next: string[] = [];
    let written = false;

    for (const line of lines) {
      if (keyPattern.test(line)) {
        if (!written) {
          next.push(`${key}=${value}`);
          written = true;
        }
        continue;
      }
      next.push(line);
    }

    if (!written) {
      if (next.length > 0 && next[next.length - 1].trim().length > 0) {
        next.push("");
      }
      next.push(`${key}=${value}`);
    }

    return next.join("\n");
  }

  private deleteEnvVariable(content: string, key: string): string {
    const lines = content.split(/\r?\n/);
    const keyPattern = new RegExp(`^\\s*${this.escapeRegex(key)}\\s*=`);
    return lines.filter((line) => !keyPattern.test(line)).join("\n");
  }

  private escapeRegex(value: string): string {
    return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  }

  private runOpsBackupData(): void {
    const agent = this.getSelectedAgent();
    if (agent === null) {
      return;
    }
    this.runOpsScript("backup-data", BACKUP_SCRIPT, ["backup", agent.name]);
  }

  private runOpsBackupConfig(): void {
    const agent = this.getSelectedAgent();
    if (agent === null) {
      return;
    }
    const backupFile = this.createConfigBackup(agent.name);
    if (backupFile === null) {
      this.message = "Config backup failed";
      this.renderAll();
      return;
    }
    this.message = `Config backup created: ${relative(ROOT_DIR, backupFile)}`;
    this.appendOpsOutput(`[ok] config backup ${relative(ROOT_DIR, backupFile)}`);
    this.renderAll();
  }

  private runOpsListBackups(): void {
    const agent = this.getSelectedAgent();
    if (agent === null) {
      return;
    }
    this.runOpsScript("list-backups", BACKUP_SCRIPT, ["list", agent.name]);
  }

  private runOpsSyncToMinio(): void {
    const agent = this.getSelectedAgent();
    if (agent === null) {
      return;
    }
    this.runOpsScript("sync-to-minio", BACKUP_SCRIPT, ["sync-to-minio", agent.name]);
  }

  private runOpsSyncFromMinio(): void {
    const agent = this.getSelectedAgent();
    if (agent === null) {
      return;
    }
    this.runOpsScript("sync-from-minio", BACKUP_SCRIPT, ["sync-from-minio", agent.name, "latest"], "n\n");
  }

  private runOpsLitestreamStatus(): void {
    const agent = this.getSelectedAgent();
    if (agent === null) {
      return;
    }
    this.runOpsScript("litestream-status", LITESTREAM_SCRIPT, ["status", agent.name]);
  }

  private runOpsLitestreamSnapshot(): void {
    const agent = this.getSelectedAgent();
    if (agent === null) {
      return;
    }
    this.runOpsScript("litestream-snapshot", LITESTREAM_SCRIPT, ["snapshot", agent.name]);
  }

  private runOpsLitestreamLogs(): void {
    const agent = this.getSelectedAgent();
    if (agent === null) {
      return;
    }
    this.runOpsScript("litestream-logs", LITESTREAM_SCRIPT, ["logs", agent.name]);
  }

  private promptOpsRestoreBackup(): void {
    const agent = this.getSelectedAgent();
    if (agent === null) {
      return;
    }
    this.openPrompt({
      title: `Restore backup for ${agent.name} (file path or filename in .backups/)`,
      placeholder: `${agent.name}-latest.tar.gz`,
      initialValue: `${agent.name}-latest.tar.gz`,
      handler: (value) => {
        if (value.length === 0) {
          this.message = "Restore cancelled";
          this.renderAll();
          return;
        }
        this.runOpsScript("restore-backup", BACKUP_SCRIPT, ["restore", agent.name, value], "restore\n");
      },
    });
  }

  private promptOpsRestoreLitestream(): void {
    const agent = this.getSelectedAgent();
    if (agent === null) {
      return;
    }
    this.openPrompt({
      title: `Litestream restore point for ${agent.name} (latest or YYYY-MM-DD HH:MM:SS)`,
      placeholder: "latest",
      initialValue: "latest",
      handler: (value) => {
        const point = value.length === 0 ? "latest" : value;
        this.runOpsScript("litestream-restore", LITESTREAM_SCRIPT, ["restore", agent.name, point], "y\n");
      },
    });
  }

  private runOpsScript(label: string, script: string, args: string[], input?: string): void {
    const out = spawnSync(script, args, {
      cwd: ROOT_DIR,
      encoding: "utf-8",
      input,
    });
    const output = `${out.stdout ?? ""}${out.stderr ?? ""}`.trim();
    const ok = out.status === 0;
    this.message = ok ? `${label} completed` : `${label} failed`;
    this.appendOpsOutput(`$ ${relative(ROOT_DIR, script)} ${args.join(" ")}`);
    if (output.length > 0) {
      const lines = output.split("\n").slice(-20);
      for (const line of lines) {
        this.appendOpsOutput(line);
      }
    }
    if (!ok) {
      this.appendOpsOutput(`[error] exit code ${out.status ?? 1}`);
    }
    this.renderAll();
  }

  private appendOpsOutput(line: string): void {
    this.opsOutput.push(line);
    if (this.opsOutput.length > 400) {
      this.opsOutput = this.opsOutput.slice(this.opsOutput.length - 400);
    }
  }

  private createConfigBackup(agentName: string): string | null {
    const agentDir = join(AGENTS_DIR, agentName);
    if (!existsSync(agentDir)) {
      return null;
    }
    if (!existsSync(BACKUPS_DIR)) {
      mkdirSync(BACKUPS_DIR, { recursive: true });
    }
    const timestamp = this.makeTimestamp();
    const archive = join(BACKUPS_DIR, `${agentName}-config-${timestamp}.tar.gz`);
    const out = spawnSync("tar", ["czf", archive, "-C", AGENTS_DIR, agentName], {
      cwd: ROOT_DIR,
      encoding: "utf-8",
    });
    if (out.status !== 0) {
      this.appendOpsOutput(`tar backup failed: ${(out.stderr || out.stdout || "unknown").trim()}`);
      return null;
    }
    return archive;
  }

  private makeTimestamp(): string {
    const now = new Date();
    const two = (n: number): string => n.toString().padStart(2, "0");
    return `${now.getFullYear()}${two(now.getMonth() + 1)}${two(now.getDate())}-${two(now.getHours())}${two(now.getMinutes())}${two(now.getSeconds())}`;
  }

  private guardUnsaved(action: () => void): void {
    if (!this.unsaved) {
      action();
      return;
    }
    this.openPrompt({
      title: "Unsaved changes. Type 'discard' to continue.",
      placeholder: "discard",
      handler: (value) => {
        if (value !== "discard") {
          this.message = "Stayed on current file";
          this.renderAll();
          return;
        }
        this.unsaved = false;
        action();
      },
    });
  }

  private runSelectedAgentCommand(command: "start" | "stop" | "restart"): void {
    const agent = this.getSelectedAgent();
    if (agent === null) {
      return;
    }
    this.runAgentCommand([command, agent.name], `${command} finished for ${agent.name}`);
  }

  private duplicateSelectedAgent(): void {
    const agent = this.getSelectedAgent();
    if (agent === null) {
      return;
    }

    this.openPrompt({
      title: `Duplicate agent ${agent.name} to new name`,
      placeholder: `${agent.name}-copy`,
      initialValue: `${agent.name}-copy`,
      handler: (value) => {
        const newName = value.trim();
        if (!/^[a-z0-9][a-z0-9_-]*$/.test(newName)) {
          this.message = "Invalid agent name. Use lowercase letters, numbers, _ or -";
          this.renderAll();
          return;
        }
        if (newName === agent.name) {
          this.message = "New name must differ from source agent";
          this.renderAll();
          return;
        }

        const targetDir = join(AGENTS_DIR, newName);
        if (existsSync(targetDir)) {
          this.message = `Target agent already exists: ${newName}`;
          this.renderAll();
          return;
        }

        cpSync(agent.dir, targetDir, { recursive: true, force: false, errorOnExist: true });

        const newEnv = join(targetDir, ".env");
        const updatedEnv = this.upsertEnvVariable(this.safeRead(newEnv), "AGENT_NAME", newName);
        writeFileSync(newEnv, updatedEnv, "utf-8");

        this.refreshAgents();
        const idx = this.agents.findIndex((a) => a.name === newName);
        if (idx >= 0) {
          this.selectedAgentIndex = idx;
        }
        this.message = `Duplicated ${agent.name} -> ${newName}. Add compose service/profile before start.`;
        this.renderAll();
      },
    });
  }

  private runAgentCommand(args: string[], successMessage: string): void {
    const out = spawnSync(AGENT_SCRIPT, args, {
      cwd: ROOT_DIR,
      encoding: "utf-8",
    });

    if (out.status === 0) {
      this.message = successMessage;
    } else {
      const err = (out.stderr || out.stdout || "Unknown error").split("\n")[0];
      this.message = `Command failed: ${err}`;
    }

    this.refreshAgents();
    this.restartLogStreamIfNeeded();
    this.renderAll();
  }

  private discoverToolCatalog(): ToolCatalogItem[] {
    const catalogDir = join(AGENT_TOOLS_REPO, "tools");
    if (!existsSync(catalogDir)) {
      return [];
    }

    const entries = readdirSync(catalogDir, { withFileTypes: true }).filter((entry) => entry.isDirectory());
    const items: ToolCatalogItem[] = [];

    for (const entry of entries) {
      const toolDir = join(catalogDir, entry.name);
      const toolToml = join(toolDir, "TOOL.toml");
      if (!existsSync(toolToml)) {
        continue;
      }
      const content = this.safeRead(toolToml);
      const name = content.match(/^name\s*=\s*"([^"]+)"/m)?.[1] ?? entry.name;
      const description = content.match(/^description\s*=\s*"([^"]+)"/m)?.[1] ?? "No description provided.";
      const output = content.match(/^output\s*=\s*"([^"]+)"/m)?.[1] ?? "";
      if (output.length === 0) {
        continue;
      }
      const binaryPath = join(AGENT_TOOLS_REPO, output);
      const binary = basename(binaryPath);
      items.push({
        id: entry.name,
        name,
        description,
        binary,
        sourcePath: binaryPath,
      });
    }

    items.sort((a, b) => a.name.localeCompare(b.name));
    return items;
  }

  private promptInstallToolFromCatalog(): void {
    const agent = this.getSelectedAgent();
    if (agent === null) {
      return;
    }

    const catalog = this.discoverToolCatalog();
    if (catalog.length === 0) {
      this.message = "No catalog tools found in ../agent-tools/tools";
      this.renderAll();
      return;
    }

    const preview = catalog.slice(0, 8).map((item, idx) => `${idx + 1}:${item.name}`).join("  ");
    this.openPrompt({
      title: `Install catalog tool (${preview})`,
      placeholder: "tool name or index",
      handler: (value) => {
        const raw = value.trim();
        if (raw.length === 0) {
          this.message = "Catalog install cancelled";
          this.renderAll();
          return;
        }

        let item: ToolCatalogItem | undefined;
        const asIndex = Number.parseInt(raw, 10);
        if (!Number.isNaN(asIndex) && asIndex >= 1 && asIndex <= catalog.length) {
          item = catalog[asIndex - 1];
        } else {
          item = catalog.find((entry) => entry.name === raw || entry.id === raw || entry.binary === raw);
        }

        if (item === undefined) {
          this.message = `Tool not found in catalog: ${raw}`;
          this.renderAll();
          return;
        }

        if (!existsSync(item.sourcePath)) {
          this.message = `Binary missing: ${item.sourcePath}. Build it in ../agent-tools first.`;
          this.renderAll();
          return;
        }

        const toolsToml = this.ensureToolsToml(agent);
        let content = this.safeRead(toolsToml).trimEnd();
        if (this.hasToolName(content, item.name)) {
          this.message = `Tool already declared: ${item.name}`;
          this.renderAll();
          return;
        }

        const block = [
          "[[tool]]",
          `name = "${item.name}"`,
          'source = "path"',
          `path = "${item.sourcePath}"`,
          `binary = "${item.binary}"`,
          `description = "${item.description.replace(/"/g, "\\\"")}"`,
        ].join("\n");

        content = `${content.length > 0 ? `${content}\n\n` : ""}${block}\n`;
        writeFileSync(toolsToml, content, "utf-8");
        this.message = `Added catalog tool '${item.name}' to ${relative(ROOT_DIR, toolsToml)}`;
        this.loadCurrentFileByPath(toolsToml);
        this.renderAll();
      },
    });
  }

  private promptAddAptPackages(): void {
    const agent = this.getSelectedAgent();
    if (agent === null) {
      return;
    }
    this.openPrompt({
      title: "Add APT package(s) to tools.toml [apt]",
      placeholder: "jq ripgrep fd-find",
      handler: (value) => {
        const names = value.split(/[\s,]+/).map((v) => v.trim()).filter((v) => v.length > 0);
        if (names.length === 0) {
          this.message = "APT package update cancelled";
          this.renderAll();
          return;
        }
        const toolsToml = this.ensureToolsToml(agent);
        let content = this.safeRead(toolsToml);
        const existing = this.parseTomlStringArray(content, "apt");
        content = this.upsertTomlStringArray(content, "apt", [...existing, ...names]);
        writeFileSync(toolsToml, content, "utf-8");
        this.message = `Added APT packages to ${relative(ROOT_DIR, toolsToml)}`;
        this.loadCurrentFileByPath(toolsToml);
        this.renderAll();
      },
    });
  }

  private promptAddBunPackages(): void {
    const agent = this.getSelectedAgent();
    if (agent === null) {
      return;
    }
    this.openPrompt({
      title: "Add Bun global package(s) to tools.toml [bun]",
      placeholder: "typescript tsx @openai/codex",
      handler: (value) => {
        const names = value.split(/[\s,]+/).map((v) => v.trim()).filter((v) => v.length > 0);
        if (names.length === 0) {
          this.message = "Bun package update cancelled";
          this.renderAll();
          return;
        }
        const toolsToml = this.ensureToolsToml(agent);
        let content = this.safeRead(toolsToml);
        const existing = this.parseTomlStringArray(content, "bun");
        content = this.upsertTomlStringArray(content, "bun", [...existing, ...names]);
        writeFileSync(toolsToml, content, "utf-8");
        this.message = `Added Bun packages to ${relative(ROOT_DIR, toolsToml)}`;
        this.loadCurrentFileByPath(toolsToml);
        this.renderAll();
      },
    });
  }

  private newFileForCurrentView(): void {
    const agent = this.getSelectedAgent();
    if (agent === null) {
      return;
    }

    let baseDir: string | null = null;
    let suggested = "";

    if (this.currentView === "skills") {
      baseDir = join(agent.dir, "skills");
      suggested = "my-skill/SKILL.md";
    } else if (this.currentView === "tools") {
      baseDir = join(agent.dir, "tools");
      suggested = "my-tool.sh";
    } else if (this.currentView === "identity") {
      baseDir = agent.dir;
      suggested = "NOTES.md";
    }

    if (baseDir === null) {
      this.message = "New file is supported in Identity/Skills/Tools views";
      this.renderAll();
      return;
    }

    this.openPrompt({
      title: `Create file relative to ${relative(ROOT_DIR, baseDir)}`,
      placeholder: suggested,
      initialValue: suggested,
      handler: (value) => {
        const relativePath = value.trim();
        if (relativePath.length === 0) {
          this.message = "File creation cancelled";
          this.renderAll();
          return;
        }

        const target = join(baseDir, relativePath);
        const safeBase = `${baseDir}/`;
        const safeTarget = `${target}`;
        if (!safeTarget.startsWith(safeBase)) {
          this.message = "Refused: path escapes agent directory";
          this.renderAll();
          return;
        }

        const parent = dirname(target);
        if (!existsSync(parent)) {
          mkdirSync(parent, { recursive: true });
        }
        if (!existsSync(target)) {
          writeFileSync(target, "", "utf-8");
        }

        this.message = `Created ${relative(ROOT_DIR, target)}`;
        this.loadCurrentFileByPath(target);
        this.renderAll();
      },
    });
  }

  private renameSelectedSkillFile(): void {
    const agent = this.getSelectedAgent();
    if (agent === null || this.currentFilePath === null) {
      return;
    }
    const skillsDir = join(agent.dir, "skills");
    const source = this.currentFilePath;
    if (!this.isPathInside(source, skillsDir)) {
      this.message = "Selected file is not inside skills directory";
      this.renderAll();
      return;
    }

    const currentRel = relative(skillsDir, source);
    this.openPrompt({
      title: `Rename skill file: ${currentRel}`,
      placeholder: currentRel,
      initialValue: currentRel,
      handler: (value) => {
        const nextRel = value.trim();
        if (nextRel.length === 0 || nextRel === currentRel) {
          this.message = "Rename cancelled";
          this.renderAll();
          return;
        }
        const target = join(skillsDir, nextRel);
        if (!this.isPathInside(target, skillsDir)) {
          this.message = "Refused: target path escapes skills directory";
          this.renderAll();
          return;
        }
        if (existsSync(target)) {
          this.message = "Rename aborted: target already exists";
          this.renderAll();
          return;
        }
        const parent = dirname(target);
        if (!existsSync(parent)) {
          mkdirSync(parent, { recursive: true });
        }
        renameSync(source, target);
        this.message = `Renamed skill: ${currentRel} -> ${nextRel}`;
        this.loadCurrentFileByPath(target);
        this.renderAll();
      },
    });
  }

  private copySelectedSkillFile(): void {
    const agent = this.getSelectedAgent();
    if (agent === null || this.currentFilePath === null) {
      return;
    }
    const skillsDir = join(agent.dir, "skills");
    const source = this.currentFilePath;
    if (!this.isPathInside(source, skillsDir)) {
      this.message = "Selected file is not inside skills directory";
      this.renderAll();
      return;
    }

    const currentRel = relative(skillsDir, source);
    const suggested = this.suggestCopyName(currentRel);
    this.openPrompt({
      title: `Copy skill file: ${currentRel}`,
      placeholder: suggested,
      initialValue: suggested,
      handler: (value) => {
        const nextRel = value.trim();
        if (nextRel.length === 0) {
          this.message = "Copy cancelled";
          this.renderAll();
          return;
        }
        const target = join(skillsDir, nextRel);
        if (!this.isPathInside(target, skillsDir)) {
          this.message = "Refused: target path escapes skills directory";
          this.renderAll();
          return;
        }
        if (existsSync(target)) {
          this.message = "Copy aborted: target already exists";
          this.renderAll();
          return;
        }
        const parent = dirname(target);
        if (!existsSync(parent)) {
          mkdirSync(parent, { recursive: true });
        }
        copyFileSync(source, target);
        this.message = `Copied skill: ${currentRel} -> ${nextRel}`;
        this.loadCurrentFileByPath(target);
        this.renderAll();
      },
    });
  }

  private suggestCopyName(relativePath: string): string {
    const dot = relativePath.lastIndexOf(".");
    if (dot <= 0) {
      return `${relativePath}-copy`;
    }
    return `${relativePath.slice(0, dot)}-copy${relativePath.slice(dot)}`;
  }

  private isPathInside(pathToCheck: string, baseDir: string): boolean {
    const normalizedBase = `${baseDir}/`;
    return pathToCheck === baseDir || pathToCheck.startsWith(normalizedBase);
  }

  private deleteCurrentFileIfAllowed(): void {
    if (this.currentFilePath === null) {
      this.message = "No file selected";
      this.renderAll();
      return;
    }

    if (!(this.currentView === "skills" || this.currentView === "tools" || this.currentView === "identity")) {
      this.message = "Deletion allowed only in Identity/Skills/Tools views";
      this.renderAll();
      return;
    }

    const target = this.currentFilePath;
    const display = relative(ROOT_DIR, target);

    this.openPrompt({
      title: `Delete ${display}. Type 'delete' to confirm.`,
      placeholder: "delete",
      handler: (value) => {
        if (value !== "delete") {
          this.message = "Deletion cancelled";
          this.renderAll();
          return;
        }
        if (existsSync(target)) {
          rmSync(target);
        }
        this.unsaved = false;
        this.message = `Deleted ${display}`;
        this.loadCurrentFile();
        this.renderAll();
      },
    });
  }

  private loadCurrentFileByPath(pathToSelect: string): void {
    const files = this.getFilesForCurrentView();
    const idx = files.findIndex((path) => path === pathToSelect);
    if (idx >= 0) {
      this.setCurrentFileIndex(idx);
    }
    this.loadCurrentFile();
  }

  private removeAgentDirectory(agentName: string): void {
    const agentDir = join(AGENTS_DIR, agentName);
    if (!existsSync(agentDir)) {
      this.message = `Agent ${agentName} does not exist`;
      this.renderAll();
      return;
    }

    this.appendOpsOutput(`[remove] starting safe removal for ${agentName}`);

    const dataBackup = spawnSync(BACKUP_SCRIPT, ["backup", agentName], {
      cwd: ROOT_DIR,
      encoding: "utf-8",
    });
    if (dataBackup.status !== 0) {
      this.message = `Data backup failed for ${agentName}; removal aborted`;
      const details = `${dataBackup.stdout ?? ""}${dataBackup.stderr ?? ""}`.trim();
      if (details.length > 0) {
        this.appendOpsOutput(details.split("\n").slice(-5).join("\n"));
      }
      this.renderAll();
      return;
    }

    const configBackup = this.createConfigBackup(agentName);
    if (configBackup === null) {
      this.message = `Config backup failed for ${agentName}; removal aborted`;
      this.renderAll();
      return;
    }

    this.appendOpsOutput(`[remove] backups created for ${agentName}`);

    const down = spawnSync("docker", [
      "compose",
      "-f",
      "docker-compose.agents.yml",
      "--profile",
      agentName,
      "down",
      "--volumes",
    ], {
      cwd: ROOT_DIR,
      encoding: "utf-8",
    });
    if (down.status !== 0) {
      this.message = `Could not stop/prune ${agentName}; removal aborted`;
      const details = `${down.stdout ?? ""}${down.stderr ?? ""}`.trim();
      if (details.length > 0) {
        this.appendOpsOutput(details.split("\n").slice(-6).join("\n"));
      }
      this.renderAll();
      return;
    }

    rmSync(agentDir, { recursive: true, force: true });
    this.message = `Removed ${agentName}; data and config backups created in .backups/`;
    this.appendOpsOutput(`[remove] deleted ${relative(ROOT_DIR, agentDir)}`);
    this.appendOpsOutput(`[remove] update docker-compose.agents.yml if service exists`);
    this.refreshAgents();
    this.renderAll();
  }

  private startLogStream(): void {
    this.stopLogStream();
    const agent = this.getSelectedAgent();
    if (agent === null) {
      return;
    }
    this.logs = [`Starting log stream for ${agent.name}...`];
    this.logProcess = spawn(
      "docker",
      ["compose", "-f", "docker-compose.agents.yml", "--profile", agent.name, "logs", "-f", "server"],
      { cwd: ROOT_DIR },
    );

    this.logProcess.stdout.on("data", (buf: Buffer) => {
      this.appendLog(buf.toString("utf-8"));
    });
    this.logProcess.stderr.on("data", (buf: Buffer) => {
      this.appendLog(buf.toString("utf-8"));
    });
    this.logProcess.on("close", (code) => {
      this.appendLog(`\n(log stream closed with code ${code ?? 0})`);
      this.logProcess = null;
    });
    this.renderAll();
  }

  private stopLogStream(): void {
    if (this.logProcess !== null) {
      this.logProcess.kill("SIGTERM");
      this.logProcess = null;
    }
  }

  private restartLogStreamIfNeeded(): void {
    if (this.currentView === "logs") {
      this.startLogStream();
    }
  }

  private appendLog(chunk: string): void {
    const pieces = chunk.replace(/\r/g, "").split("\n");
    for (const piece of pieces) {
      if (piece.length === 0) {
        continue;
      }
      this.logs.push(piece);
    }
    if (this.logs.length > 800) {
      this.logs = this.logs.slice(this.logs.length - 800);
    }
    this.renderAll();
  }

  private openPrompt(state: PromptState): void {
    this.promptState = state;
    this.promptTitleText.content = state.title;
    this.promptInput.placeholder = state.placeholder;
    this.promptInput.value = state.initialValue ?? "";
    this.promptOverlay.visible = true;
    this.promptInput.focus();
    this.renderAll();
  }

  private closePrompt(): void {
    this.promptState = null;
    this.promptOverlay.visible = false;
    this.renderAll();
  }

  private submitPrompt(): void {
    if (this.promptState === null) {
      return;
    }
    const value = this.promptInput.value.trim();
    const handler = this.promptState.handler;
    this.closePrompt();
    handler(value);
  }

  private safeRead(path: string): string {
    if (!existsSync(path)) {
      return "";
    }
    if (!statSync(path).isFile()) {
      return "";
    }
    return readFileSync(path, "utf-8");
  }

  private loadEditorContentForPath(filePath: string): { content: string; readOnly: boolean } {
    if (this.currentView !== "tools") {
      return { content: this.safeRead(filePath), readOnly: false };
    }

    if (!this.isProbablyBinaryFile(filePath)) {
      return { content: this.safeRead(filePath), readOnly: false };
    }

    const description = this.getToolDescription(filePath);
    const relPath = relative(ROOT_DIR, filePath);
    const lines = [
      `Binary tool: ${relPath}`,
      `Description: ${description}`,
      "",
      "Binary contents are not displayed in the TUI.",
      "Use shell to inspect behavior, for example:",
      `  ${basename(filePath)} --help`,
    ];
    return { content: lines.join("\n"), readOnly: true };
  }

  private isProbablyBinaryFile(filePath: string): boolean {
    const buf = readFileSync(filePath);
    if (buf.length === 0) {
      return false;
    }

    const sampleLen = Math.min(buf.length, 8192);
    let suspicious = 0;
    for (let i = 0; i < sampleLen; i++) {
      const byte = buf[i];
      if (byte === 0) {
        return true;
      }
      const isTabOrNewline = byte === 9 || byte === 10 || byte === 13;
      const isPrintableAscii = byte >= 32 && byte <= 126;
      if (!isTabOrNewline && !isPrintableAscii) {
        suspicious += 1;
      }
    }

    return suspicious / sampleLen > 0.3;
  }

  private getToolDescription(filePath: string): string {
    const metaPath = join(dirname(filePath), `.${basename(filePath)}.tool`);
    if (existsSync(metaPath) && statSync(metaPath).isFile()) {
      const meta = this.parseEnv(this.safeRead(metaPath));
      const description = meta.description?.trim();
      if (description !== undefined && description.length > 0) {
        return description;
      }
    }
    return "No description provided.";
  }
}

async function main(): Promise<void> {
  const app = new AgentManagerTui();
  await app.start();
}

main().catch((error) => {
  const message = error instanceof Error ? error.stack || error.message : String(error);
  process.stderr.write(`Failed to start TUI: ${message}\n`);
  process.exit(1);
});
