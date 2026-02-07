// Patch os.uptime/process.uptime to avoid EPERM in restricted environments.
try {
  const os = require("os");
  os.uptime = () => 0;
} catch (_) {}

try {
  process.uptime = () => 0;
} catch (_) {}
