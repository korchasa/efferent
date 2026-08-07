/** Regenerate the Xcode project from `Project.swift`. */

import { run, section } from "./lib.ts";
import { PROJECT } from "./config.ts";

export async function generate(): Promise<void> {
  section("Generating the Xcode project");
  // Both are gitignored build products. Dropping them first stops `tuist
  // generate` from tripping over a stale Package.resolved symlink left behind
  // when the checkout moved.
  await Deno.remove(`${PROJECT}.xcworkspace`, { recursive: true }).catch(() => {});
  await Deno.remove(`${PROJECT}.xcodeproj`, { recursive: true }).catch(() => {});

  await run("tuist", { args: ["install"] });
  await run("tuist", { args: ["generate", "--no-open"] });
}

if (import.meta.main) await generate();
