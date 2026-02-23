/**
 * First-run setup wizard — detects what's installed, installs missing deps,
 * initializes the database, generates certs, and clones relaycreator.
 */

import { join } from "path";
import { existsSync, writeFileSync } from "fs";
import type { PlatformInfo } from "../lib/platform";
import type { ServiceManager } from "./manager";

export interface SetupStep {
  id: string;
  label: string;
  status: "pending" | "running" | "done" | "error" | "skipped";
  message?: string;
}

export interface SetupStatus {
  running: boolean;
  currentStep: string | null;
  steps: SetupStep[];
}

export class SetupWizard {
  private platform: PlatformInfo;
  private services: ServiceManager;
  private steps: SetupStep[] = [];
  private running = false;
  private currentStep: string | null = null;

  constructor(platform: PlatformInfo, services: ServiceManager) {
    this.platform = platform;
    this.services = services;
    this.initSteps();
  }

  private initSteps() {
    const isWindows = this.platform.os === "windows";
    this.steps = [
      { id: "mariadb", label: "Install MariaDB", status: "pending" },
      { id: "mariadb_init", label: "Initialize database", status: "pending" },
      ...(isWindows
        ? [{ id: "wsl2", label: "Check WSL2 + Ubuntu", status: "pending" as const }]
        : []),
      { id: "strfry", label: "Install strfry relay", status: "pending" },
      { id: "mkcert", label: "Generate TLS certificates", status: "pending" },
      { id: "relaycreator", label: "Clone & build relaycreator", status: "pending" },
      { id: "env", label: "Generate configuration", status: "pending" },
      { id: "prisma", label: "Run database migrations", status: "pending" },
    ];
  }

  async needsFirstRun(): Promise<boolean> {
    const envFile = join(this.platform.dataDir, "relaycreator", ".env");
    const rcDir = join(this.platform.dataDir, "relaycreator", "api-server");
    return !existsSync(envFile) || !existsSync(rcDir);
  }

  async checkRequirements(): Promise<{
    mariadb: boolean;
    strfry: boolean;
    mkcert: boolean;
    relaycreator: boolean;
    wsl2?: boolean;
    bun: boolean;
    node: boolean;
  }> {
    const check = (cmd: string[]): boolean => {
      try {
        const result = Bun.spawnSync(cmd, { stdout: "pipe", stderr: "pipe" });
        return result.exitCode === 0;
      } catch {
        return false;
      }
    };

    const isWindows = this.platform.os === "windows";

    const result: any = {
      mariadb: check(["mysql", "--version"]),
      mkcert: check(["mkcert", "-version"]),
      relaycreator: existsSync(join(this.platform.dataDir, "relaycreator", "api-server")),
      bun: check(["bun", "--version"]),
      node: check(["node", "--version"]),
    };

    if (isWindows) {
      // Check WSL2 Ubuntu
      try {
        const r = Bun.spawnSync(["wsl", "--list", "--quiet"], { stdout: "pipe" });
        const output = new TextDecoder().decode(r.stdout).replace(/\0/g, "");
        result.wsl2 = output.includes("Ubuntu");
      } catch {
        result.wsl2 = false;
      }
      // Check strfry inside WSL
      try {
        const r = Bun.spawnSync(["wsl", "-d", "Ubuntu", "--", "which", "strfry"], { stdout: "pipe" });
        result.strfry = r.exitCode === 0;
      } catch {
        result.strfry = false;
      }
    } else {
      result.strfry = check(["which", "strfry"]);
    }

    return result;
  }

  private setStep(id: string, status: SetupStep["status"], message?: string) {
    const step = this.steps.find((s) => s.id === id);
    if (step) {
      step.status = status;
      if (message) step.message = message;
    }
    this.currentStep = status === "running" ? id : this.currentStep;
    console.log(`[setup] ${id}: ${status}${message ? ` — ${message}` : ""}`);
  }

  async runSetup(): Promise<SetupStatus> {
    if (this.running) return this.getStatus();
    this.running = true;
    this.initSteps();

    try {
      const reqs = await this.checkRequirements();

      // ── MariaDB ──
      if (reqs.mariadb) {
        this.setStep("mariadb", "skipped", "Already installed");
      } else {
        this.setStep("mariadb", "running");
        await this.installMariaDB();
        this.setStep("mariadb", "done");
      }

      // ── MariaDB init ──
      this.setStep("mariadb_init", "running");
      await this.initDatabase();
      this.setStep("mariadb_init", "done");

      // ── WSL2 (Windows only) ──
      if (this.platform.os === "windows") {
        if (reqs.wsl2) {
          this.setStep("wsl2", "skipped", "WSL2 Ubuntu already installed");
        } else {
          this.setStep("wsl2", "running");
          this.setStep("wsl2", "error", "WSL2 Ubuntu required — install via: wsl --install -d Ubuntu");
          this.running = false;
          return this.getStatus();
        }
      }

      // ── strfry ──
      if (reqs.strfry) {
        this.setStep("strfry", "skipped", "Already installed");
      } else {
        this.setStep("strfry", "running");
        await this.installStrfry();
        this.setStep("strfry", "done");
      }

      // ── mkcert ──
      this.setStep("mkcert", "running");
      await this.setupCerts();
      this.setStep("mkcert", "done");

      // ── relaycreator ──
      if (reqs.relaycreator) {
        this.setStep("relaycreator", "skipped", "Already cloned");
      } else {
        this.setStep("relaycreator", "running");
        await this.cloneRelaycreator();
        this.setStep("relaycreator", "done");
      }

      // ── .env ──
      this.setStep("env", "running");
      await this.generateEnv();
      this.setStep("env", "done");

      // ── Prisma migrations ──
      this.setStep("prisma", "running");
      await this.runMigrations();
      this.setStep("prisma", "done");

    } catch (err: any) {
      console.error("[setup] Fatal:", err);
      if (this.currentStep) {
        this.setStep(this.currentStep, "error", err.message);
      }
    }

    this.running = false;
    return this.getStatus();
  }

  getStatus(): SetupStatus {
    return {
      running: this.running,
      currentStep: this.currentStep,
      steps: [...this.steps],
    };
  }

  // ─── Individual setup steps ────────────────────────────────────────────

  private async installMariaDB(): Promise<void> {
    if (this.platform.os === "windows") {
      const r = Bun.spawnSync(
        ["winget", "install", "--id", "MariaDB.Server", "-e", "--accept-source-agreements", "--accept-package-agreements"],
        { stdout: "pipe", stderr: "pipe" }
      );
      if (r.exitCode !== 0) throw new Error("Failed to install MariaDB via winget");
    } else {
      const r = Bun.spawnSync(
        ["sudo", "apt-get", "install", "-y", "mariadb-server"],
        { stdout: "pipe", stderr: "pipe" }
      );
      if (r.exitCode !== 0) throw new Error("Failed to install MariaDB via apt");
    }
  }

  private async initDatabase(): Promise<void> {
    // Generate a random password
    const chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    let password = "";
    for (let i = 0; i < 24; i++) {
      password += chars[Math.floor(Math.random() * chars.length)];
    }

    // Store password for .env generation
    (this as any)._dbPassword = password;

    const sql = [
      `CREATE DATABASE IF NOT EXISTS relaycreator;`,
      `CREATE USER IF NOT EXISTS 'relaycreator'@'localhost' IDENTIFIED BY '${password}';`,
      `GRANT ALL PRIVILEGES ON relaycreator.* TO 'relaycreator'@'localhost';`,
      `ALTER USER 'relaycreator'@'localhost' IDENTIFIED BY '${password}';`,
      `FLUSH PRIVILEGES;`,
    ].join("\n");

    const r = Bun.spawnSync(["mysql", "-u", "root", "-e", sql], { stdout: "pipe", stderr: "pipe" });
    if (r.exitCode !== 0) {
      const err = new TextDecoder().decode(r.stderr);
      throw new Error(`DB init failed: ${err}`);
    }
  }

  private async installStrfry(): Promise<void> {
    if (this.platform.os === "windows") {
      // Build strfry inside WSL2
      const script = [
        "#!/bin/bash",
        "set -e",
        "apt-get update && apt-get install -y git build-essential cmake libsecp256k1-dev liblmdb-dev libflatbuffers-dev libssl-dev zlib1g-dev",
        "cd /tmp && rm -rf strfry",
        "git clone https://github.com/hoytech/strfry.git",
        "cd strfry && git submodule update --init",
        "make setup-golpe && make -j$(nproc)",
        "cp strfry /usr/local/bin/strfry",
        "echo 'strfry installed successfully'",
      ].join("\n");

      const tmpFile = join(this.platform.dataDir, "build-strfry.sh");
      writeFileSync(tmpFile, script, { mode: 0o755 });
      const wslPath = tmpFile.replace(/\\/g, "/").replace(/^([A-Z]):/, (_, d: string) => `/mnt/${d.toLowerCase()}`);

      const r = Bun.spawnSync(["wsl", "-d", "Ubuntu", "-u", "root", "--", "bash", wslPath], {
        stdout: "pipe", stderr: "pipe",
      });
      if (r.exitCode !== 0) throw new Error("strfry build failed in WSL2");
    } else {
      // Native Linux build
      const r = Bun.spawnSync(["bash", "-c", [
        "set -e",
        "sudo apt-get install -y git build-essential cmake libsecp256k1-dev liblmdb-dev libflatbuffers-dev libssl-dev zlib1g-dev",
        "cd /tmp && rm -rf strfry",
        "git clone https://github.com/hoytech/strfry.git",
        "cd strfry && git submodule update --init",
        "make setup-golpe && make -j$(nproc)",
        "sudo cp strfry /usr/local/bin/strfry",
      ].join(" && ")], { stdout: "pipe", stderr: "pipe" });
      if (r.exitCode !== 0) throw new Error("strfry build failed");
    }
  }

  private async setupCerts(): Promise<void> {
    const certsDir = this.platform.certsDir;
    const certFile = join(certsDir, "localhost.pem");
    if (existsSync(certFile)) return; // Already done

    Bun.spawnSync(["mkcert", "-install"], { stdout: "pipe", stderr: "pipe" });
    const r = Bun.spawnSync(
      ["mkcert", "-cert-file", join(certsDir, "localhost.pem"), "-key-file", join(certsDir, "localhost-key.pem"), "localhost", "127.0.0.1", "::1"],
      { stdout: "pipe", stderr: "pipe" }
    );
    if (r.exitCode !== 0) throw new Error("mkcert failed");
  }

  private async cloneRelaycreator(): Promise<void> {
    const rcDir = join(this.platform.dataDir, "relaycreator");
    const r = Bun.spawnSync(
      ["git", "clone", "-b", "local", "https://github.com/TekkadanPlays/relaycreator.git", rcDir],
      { stdout: "pipe", stderr: "pipe" }
    );
    if (r.exitCode !== 0) throw new Error("git clone failed");

    // Install dependencies
    const apiDir = join(rcDir, "api-server");
    Bun.spawnSync(["npm", "install", "--ignore-scripts"], { cwd: apiDir, stdout: "pipe", stderr: "pipe" });
    Bun.spawnSync(["npx", "prisma", "generate"], { cwd: apiDir, stdout: "pipe", stderr: "pipe" });

    // Build frontend
    const webDir = join(rcDir, "web");
    Bun.spawnSync(["bun", "install"], { cwd: webDir, stdout: "pipe", stderr: "pipe" });
    Bun.spawnSync(["bun", "run", "build"], { cwd: webDir, stdout: "pipe", stderr: "pipe" });
  }

  private async generateEnv(): Promise<void> {
    const rcDir = join(this.platform.dataDir, "relaycreator");
    const password = (this as any)._dbPassword || "changeme";

    // Generate JWT secret
    const chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    let jwtSecret = "";
    for (let i = 0; i < 44; i++) {
      jwtSecret += chars[Math.floor(Math.random() * chars.length)];
    }

    const envContent = [
      "# relay-tools local configuration",
      `# Generated by relay-tools-desktop on ${new Date().toISOString()}`,
      `DATABASE_URL=mysql://relaycreator:${password}@localhost:3306/relaycreator`,
      `JWT_SECRET=${jwtSecret}`,
      `PORT=4000`,
      `CREATOR_DOMAIN=localhost`,
      `PAYMENTS_ENABLED=false`,
      `COINOS_ENABLED=false`,
      `INVOICE_AMOUNT=0`,
      `INVOICE_PREMIUM_AMOUNT=0`,
    ].join("\n");

    writeFileSync(join(rcDir, ".env"), envContent);
    writeFileSync(join(rcDir, "api-server", ".env"), envContent);
  }

  private async runMigrations(): Promise<void> {
    const apiDir = join(this.platform.dataDir, "relaycreator", "api-server");
    const envFile = join(this.platform.dataDir, "relaycreator", ".env");

    // Read DATABASE_URL from .env
    const envContent = Bun.file(envFile);
    const text = await envContent.text();
    const dbUrl = text.split("\n").find((l) => l.startsWith("DATABASE_URL="))?.split("=").slice(1).join("=") || "";

    const r = Bun.spawnSync(["npx", "prisma", "db", "push", "--accept-data-loss"], {
      cwd: apiDir,
      stdout: "pipe",
      stderr: "pipe",
      env: { ...process.env, DATABASE_URL: dbUrl },
    });
    if (r.exitCode !== 0) {
      const err = new TextDecoder().decode(r.stderr);
      throw new Error(`Prisma migration failed: ${err}`);
    }
  }
}
