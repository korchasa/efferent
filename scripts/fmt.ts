/** Format what this repository owns: the task scripts, and Swift if a formatter is installed. */

import { exists, run, section } from "./lib.ts";
import { RUFF } from "./reader.ts";

section("Formatting task scripts");
await run("deno", { args: ["fmt"] });

if (await exists(RUFF)) {
  section("Formatting the Python reader");
  await run(RUFF, { args: ["format", "reader"] });
  await run(RUFF, { args: ["check", "--fix", "reader"] });
} else {
  console.log("reader/.venv not set up — skipping the Python reader (deno task reader:setup)");
}

if (await exists("/opt/homebrew/bin/swiftformat")) {
  section("Formatting Swift sources");
  await run("/opt/homebrew/bin/swiftformat", { args: ["src"] });
} else {
  console.log("swiftformat not installed — skipping Swift sources");
}
