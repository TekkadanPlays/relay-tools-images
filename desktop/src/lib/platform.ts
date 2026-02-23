/**
 * Platform detection and path resolution for relay-tools-desktop.
 */

import { join } from "path";
import { existsSync, mkdirSync } from "fs";

export interface PlatformInfo {
  os: "windows" | "linux" | "darwin";
  arch: string;
  dataDir: string;
  certsDir: string;
  logsDir: string;
  binDir: string;
  strfryMode: "native" | "wsl2";
  mariadbMode: "native" | "service";
  shell: string;
}

export function detectPlatform(): PlatformInfo {
  const os = process.platform === "win32"
    ? "windows"
    : process.platform === "darwin"
      ? "darwin"
      : "linux";

  const arch = process.arch;

  // Data directory: ~/relay-tools on all platforms
  const home = process.env.HOME || process.env.USERPROFILE || "";
  const dataDir = join(home, "relay-tools");
  const certsDir = join(dataDir, "certs");
  const logsDir = join(dataDir, "logs");
  const binDir = join(dataDir, "bin");

  // Ensure directories exist
  for (const dir of [dataDir, certsDir, logsDir, binDir]) {
    if (!existsSync(dir)) {
      mkdirSync(dir, { recursive: true });
    }
  }

  return {
    os,
    arch,
    dataDir,
    certsDir,
    logsDir,
    binDir,
    strfryMode: os === "windows" ? "wsl2" : "native",
    mariadbMode: os === "windows" ? "service" : "native",
    shell: os === "windows" ? "powershell" : "bash",
  };
}
