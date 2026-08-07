/** Format what this repository owns: the task scripts, and Swift if a formatter is installed. */

import { exists, run, section } from "./lib.ts";

section("Formatting task scripts");
await run("deno", { args: ["fmt"] });

if (await exists("/opt/homebrew/bin/swiftformat")) {
  section("Formatting Swift sources");
  await run("/opt/homebrew/bin/swiftformat", { args: ["src"] });
} else {
  console.log("swiftformat not installed — skipping Swift sources");
}
