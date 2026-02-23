/**
 * Service manager — spawns and monitors MariaDB, strfry, and relaycreator API.
 * Each service is a managed child process with log capture and health monitoring.
 */

import { join } from "path";
import { existsSync, readFileSync, appendFileSync, mkdirSync } from "fs";
import type { PlatformInfo } from "../lib/platform";
import type { Subprocess } from "bun";

export interface ServiceState {
  name: string;
  status: "stopped" | "starting" | "running" | "error" | "not_installed";
  pid?: number;
  uptime?: number;
  startedAt?: number;
  lastError?: string;
}

interface ManagedService {
  name: string;
  proc: Subprocess | null;
  status: ServiceState["status"];
  startedAt: number | null;
  lastError: string | null;
  logBuffer: string[];
}

const MAX_LOG_LINES = 500;

export class ServiceManager {
  private platform: PlatformInfo;
  private services: Map<string, ManagedService> = new Map();

  constructor(platform: PlatformInfo) {
    this.platform = platform;

    // Register known services
    for (const name of ["mariadb", "strfry", "relaycreator"]) {
      this.services.set(name, {
        name,
        proc: null,
        status: "stopped",
        startedAt: null,
        lastError: null,
        logBuffer: [],
      });
    }
  }

  private log(service: string, line: string) {
    const svc = this.services.get(service);
    if (!svc) return;
    const ts = new Date().toISOString();
    const entry = `[${ts}] ${line}`;
    svc.logBuffer.push(entry);
    if (svc.logBuffer.length > MAX_LOG_LINES) {
      svc.logBuffer.shift();
    }
    // Also write to log file
    const logFile = join(this.platform.logsDir, `${service}.log`);
    try {
      appendFileSync(logFile, entry + "\n");
    } catch { /* ignore */ }
    console.log(`[${service}] ${line}`);
  }

  // ─── MariaDB ─────────────────────────────────────────────────────────────

  private async startMariaDB(): Promise<void> {
    const svc = this.services.get("mariadb")!;
    svc.status = "starting";

    if (this.platform.os === "windows") {
      // On Windows, MariaDB runs as a Windows service
      try {
        const result = Bun.spawnSync(["sc", "query", "MariaDB"], { stdout: "pipe" });
        const output = new TextDecoder().decode(result.stdout);
        if (output.includes("RUNNING")) {
          svc.status = "running";
          svc.startedAt = Date.now();
          this.log("mariadb", "Already running as Windows service");
          return;
        }
        // Try to start it
        Bun.spawnSync(["net", "start", "MariaDB"], { stdout: "pipe", stderr: "pipe" });
        svc.status = "running";
        svc.startedAt = Date.now();
        this.log("mariadb", "Started Windows service");
      } catch (err: any) {
        svc.status = "error";
        svc.lastError = err.message;
        this.log("mariadb", `Failed to start: ${err.message}`);
      }
    } else {
      // On Linux, start mariadbd directly or via systemctl
      try {
        const result = Bun.spawnSync(["systemctl", "is-active", "mariadb"], { stdout: "pipe" });
        const output = new TextDecoder().decode(result.stdout).trim();
        if (output === "active") {
          svc.status = "running";
          svc.startedAt = Date.now();
          this.log("mariadb", "Already running via systemd");
          return;
        }
        Bun.spawnSync(["sudo", "systemctl", "start", "mariadb"], { stdout: "pipe", stderr: "pipe" });
        svc.status = "running";
        svc.startedAt = Date.now();
        this.log("mariadb", "Started via systemd");
      } catch (err: any) {
        svc.status = "error";
        svc.lastError = err.message;
        this.log("mariadb", `Failed to start: ${err.message}`);
      }
    }
  }

  private async stopMariaDB(): Promise<void> {
    const svc = this.services.get("mariadb")!;
    if (this.platform.os === "windows") {
      Bun.spawnSync(["net", "stop", "MariaDB"], { stdout: "pipe", stderr: "pipe" });
    } else {
      Bun.spawnSync(["sudo", "systemctl", "stop", "mariadb"], { stdout: "pipe", stderr: "pipe" });
    }
    svc.status = "stopped";
    svc.proc = null;
    svc.startedAt = null;
    this.log("mariadb", "Stopped");
  }

  // ─── strfry ──────────────────────────────────────────────────────────────

  private async startStrfry(): Promise<void> {
    const svc = this.services.get("strfry")!;
    svc.status = "starting";

    const dataDir = join(this.platform.dataDir, "data", "strfry");
    if (!existsSync(dataDir)) {
      mkdirSync(dataDir, { recursive: true });
    }

    try {
      if (this.platform.strfryMode === "wsl2") {
        // Windows: run strfry inside WSL2
        const confPath = join(dataDir, "strfry.conf").replace(/\\/g, "/");
        const wslConfPath = confPath.replace(/^([A-Z]):/, (_, d) => `/mnt/${d.toLowerCase()}`);
        const proc = Bun.spawn(
          ["wsl", "-d", "Ubuntu", "--", "/usr/local/bin/strfry", "--config=" + wslConfPath, "relay"],
          { stdout: "pipe", stderr: "pipe" }
        );
        svc.proc = proc;
        this.pipeOutput(proc, "strfry");
      } else {
        // Linux: run strfry natively
        const confFile = join(dataDir, "strfry.conf");
        const proc = Bun.spawn(
          ["/usr/local/bin/strfry", "--config=" + confFile, "relay"],
          { stdout: "pipe", stderr: "pipe" }
        );
        svc.proc = proc;
        this.pipeOutput(proc, "strfry");
      }
      svc.status = "running";
      svc.startedAt = Date.now();
      this.log("strfry", `Started (${this.platform.strfryMode} mode, PID ${svc.proc?.pid})`);

      // Monitor for exit
      svc.proc?.exited.then((code) => {
        if (svc.status === "running") {
          svc.status = "error";
          svc.lastError = `Exited with code ${code}`;
          this.log("strfry", `Exited unexpectedly with code ${code}`);
        }
      });
    } catch (err: any) {
      svc.status = "error";
      svc.lastError = err.message;
      this.log("strfry", `Failed to start: ${err.message}`);
    }
  }

  private async stopStrfry(): Promise<void> {
    const svc = this.services.get("strfry")!;
    if (svc.proc) {
      svc.proc.kill();
      svc.proc = null;
    }
    svc.status = "stopped";
    svc.startedAt = null;
    this.log("strfry", "Stopped");
  }

  // ─── relaycreator ────────────────────────────────────────────────────────

  private async startRelaycreator(): Promise<void> {
    const svc = this.services.get("relaycreator")!;
    svc.status = "starting";

    const rcDir = join(this.platform.dataDir, "relaycreator");
    const apiDir = join(rcDir, "api-server");
    const envFile = join(rcDir, ".env");

    if (!existsSync(apiDir)) {
      svc.status = "not_installed";
      svc.lastError = "relaycreator not found — run setup first";
      this.log("relaycreator", "Not installed");
      return;
    }

    try {
      // Load .env
      const envVars: Record<string, string> = {};
      if (existsSync(envFile)) {
        const lines = readFileSync(envFile, "utf-8").split("\n");
        for (const line of lines) {
          const trimmed = line.trim();
          if (!trimmed || trimmed.startsWith("#")) continue;
          const eq = trimmed.indexOf("=");
          if (eq > 0) {
            envVars[trimmed.slice(0, eq)] = trimmed.slice(eq + 1);
          }
        }
      }

      const proc = Bun.spawn(["bun", "run", "src/index.ts"], {
        cwd: apiDir,
        stdout: "pipe",
        stderr: "pipe",
        env: { ...process.env, ...envVars },
      });
      svc.proc = proc;
      this.pipeOutput(proc, "relaycreator");
      svc.status = "running";
      svc.startedAt = Date.now();
      this.log("relaycreator", `Started (PID ${proc.pid})`);

      proc.exited.then((code) => {
        if (svc.status === "running") {
          svc.status = "error";
          svc.lastError = `Exited with code ${code}`;
          this.log("relaycreator", `Exited unexpectedly with code ${code}`);
        }
      });
    } catch (err: any) {
      svc.status = "error";
      svc.lastError = err.message;
      this.log("relaycreator", `Failed to start: ${err.message}`);
    }
  }

  private async stopRelaycreator(): Promise<void> {
    const svc = this.services.get("relaycreator")!;
    if (svc.proc) {
      svc.proc.kill();
      svc.proc = null;
    }
    svc.status = "stopped";
    svc.startedAt = null;
    this.log("relaycreator", "Stopped");
  }

  // ─── Output piping ──────────────────────────────────────────────────────

  private async pipeOutput(proc: Subprocess, service: string) {
    if (proc.stdout) {
      const reader = proc.stdout.getReader();
      const decoder = new TextDecoder();
      (async () => {
        try {
          while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            const text = decoder.decode(value);
            for (const line of text.split("\n").filter(Boolean)) {
              this.log(service, line);
            }
          }
        } catch { /* stream closed */ }
      })();
    }
    if (proc.stderr) {
      const reader = proc.stderr.getReader();
      const decoder = new TextDecoder();
      (async () => {
        try {
          while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            const text = decoder.decode(value);
            for (const line of text.split("\n").filter(Boolean)) {
              this.log(service, `[stderr] ${line}`);
            }
          }
        } catch { /* stream closed */ }
      })();
    }
  }

  // ─── Public API ─────────────────────────────────────────────────────────

  async start(service: string): Promise<ServiceState> {
    switch (service) {
      case "mariadb": await this.startMariaDB(); break;
      case "strfry": await this.startStrfry(); break;
      case "relaycreator": await this.startRelaycreator(); break;
      default: throw new Error(`Unknown service: ${service}`);
    }
    return this.getServiceState(service);
  }

  async stop(service: string): Promise<ServiceState> {
    switch (service) {
      case "mariadb": await this.stopMariaDB(); break;
      case "strfry": await this.stopStrfry(); break;
      case "relaycreator": await this.stopRelaycreator(); break;
      default: throw new Error(`Unknown service: ${service}`);
    }
    return this.getServiceState(service);
  }

  async restart(service: string): Promise<ServiceState> {
    await this.stop(service);
    await new Promise((r) => setTimeout(r, 1000));
    return this.start(service);
  }

  async startAll(): Promise<Record<string, ServiceState>> {
    // Start in dependency order: DB → relay → API
    await this.startMariaDB();
    await this.startStrfry();
    await new Promise((r) => setTimeout(r, 500));
    await this.startRelaycreator();
    return this.getStatus();
  }

  async stopAll(): Promise<void> {
    // Stop in reverse order
    await this.stopRelaycreator();
    await this.stopStrfry();
    await this.stopMariaDB();
  }

  getServiceState(name: string): ServiceState {
    const svc = this.services.get(name);
    if (!svc) return { name, status: "not_installed" };
    return {
      name: svc.name,
      status: svc.status,
      pid: svc.proc?.pid,
      uptime: svc.startedAt ? Math.floor((Date.now() - svc.startedAt) / 1000) : undefined,
      startedAt: svc.startedAt ?? undefined,
      lastError: svc.lastError ?? undefined,
    };
  }

  getStatus(): Record<string, ServiceState> {
    const result: Record<string, ServiceState> = {};
    for (const name of this.services.keys()) {
      result[name] = this.getServiceState(name);
    }
    return result;
  }

  async healthCheck(): Promise<{
    overall: "healthy" | "degraded" | "down";
    services: Record<string, ServiceState>;
  }> {
    const status = this.getStatus();
    const states = Object.values(status);
    const allRunning = states.every((s) => s.status === "running");
    const anyError = states.some((s) => s.status === "error");
    return {
      overall: allRunning ? "healthy" : anyError ? "down" : "degraded",
      services: status,
    };
  }

  getLogs(service: string, lines: number = 50): string[] {
    const svc = this.services.get(service);
    if (!svc) return [];
    return svc.logBuffer.slice(-lines);
  }
}
