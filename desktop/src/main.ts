/**
 * relay-tools-desktop — Buntralino main process
 *
 * Manages the service lifecycle:
 *   1. MariaDB (native)
 *   2. strfry (native on Linux, WSL2 on Windows)
 *   3. relaycreator API server (Bun/Node)
 *
 * Exposes methods to the Neutralino frontend for:
 *   - Service status / health checks
 *   - Start / stop / restart individual services
 *   - First-run setup wizard progress
 *   - Log streaming
 */

import * as buntralino from "buntralino";
import { ServiceManager } from "./services/manager";
import { SetupWizard } from "./services/setup";
import { detectPlatform, type PlatformInfo } from "./lib/platform";

// ─── Platform detection ──────────────────────────────────────────────────────

const platform: PlatformInfo = detectPlatform();
console.log(`[main] Platform: ${platform.os} ${platform.arch}`);
console.log(`[main] Data dir: ${platform.dataDir}`);

// ─── Service manager ─────────────────────────────────────────────────────────

const services = new ServiceManager(platform);
const setup = new SetupWizard(platform, services);

// ─── Register Bun-side methods callable from Neutralino frontend ─────────────

buntralino.registerMethodMap({
  // Health & status
  "services:status": async () => services.getStatus(),
  "services:health": async () => services.healthCheck(),
  "services:logs": async (args: { service: string; lines?: number }) =>
    services.getLogs(args.service, args.lines ?? 50),

  // Service control
  "services:start": async (args: { service: string }) =>
    services.start(args.service),
  "services:stop": async (args: { service: string }) =>
    services.stop(args.service),
  "services:restart": async (args: { service: string }) =>
    services.restart(args.service),
  "services:startAll": async () => services.startAll(),
  "services:stopAll": async () => services.stopAll(),

  // Setup wizard
  "setup:check": async () => setup.checkRequirements(),
  "setup:run": async () => setup.runSetup(),
  "setup:status": async () => setup.getStatus(),

  // Platform info
  "platform:info": async () => platform,
});

// ─── Window lifecycle ────────────────────────────────────────────────────────

buntralino.events.on("close", async (name: string) => {
  console.log(`[main] Window "${name}" closed`);
  // If the main window closes, stop all services and exit
  if (name === "main") {
    console.log("[main] Main window closed — shutting down services...");
    await services.stopAll();
    process.exit(0);
  }
});

// ─── Launch ──────────────────────────────────────────────────────────────────

async function main() {
  // Check if first run (no .env or DB not initialized)
  const needsSetup = await setup.needsFirstRun();

  // Create the main window pointing at the Neutralino frontend shell
  await buntralino.create("/index.html", {
    name: "main",
    title: needsSetup ? "Relay Tools — Setup" : "Relay Tools",
    width: 1200,
    height: 800,
    minWidth: 900,
    minHeight: 600,
    center: true,
  });

  // If setup is needed, the frontend will show the wizard.
  // Otherwise, auto-start services.
  if (!needsSetup) {
    console.log("[main] Starting services...");
    await services.startAll();
  }
}

main().catch((err) => {
  console.error("[main] Fatal error:", err);
  process.exit(1);
});
