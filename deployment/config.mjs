// Shared builder for Fly Machines configuration
// Usage:
//   import { buildMachineConfig } from "./config.mjs";
//   const cfg = buildMachineConfig({ image, stateful: false });

export function buildMachineConfig({ image, stateful = false, volumeName }) {
  const config = {
    image,
    platform: "linux/amd64",
    restart: { policy: "always" },
    auto_destroy: false,
    stop: { signal: "SIGINT", timeout: "45s" },
    guest: { cpu_kind: "shared", cpus: 1, memory_mb: 1024 },
    env: { PORT: "4000", PHX_SERVER: "true" },
    services: [
      {
        protocol: "tcp",
        internal_port: 4000,
        ports: [
          { port: 80, handlers: ["http"] },
          { port: 443, handlers: ["tls", "http"] },
        ],
        concurrency: { type: "connections", soft_limit: 500, hard_limit: 1000 },
      },
    ],
    checks: {
      http: {
        type: "http",
        port: 4000,
        path: "/api/health",
        interval: "10s",
        timeout: "2s",
        grace_period: "15s",
        method: "GET",
      },
    },
    metadata: { version: image },
  };

  if (stateful) {
    if (!volumeName) {
      throw new Error("stateful=true requires volumeName");
    }
    config.mounts = [{ volume: volumeName, path: "/data" }];
  }

  return config;
}
