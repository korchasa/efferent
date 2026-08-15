/**
 * `deno task secrets` — look for keys that should never have been written down.
 *
 * Two scans, because they answer different questions. The working directory is
 * what you are about to commit; history is what has already been published, and
 * deleting a key in a later commit does not unpublish it. CI runs the history
 * scan alone — everything in a fresh checkout is committed by definition.
 *
 * The rules are in `.gitleaks.toml`, and the one that matters is not a default:
 * this project's reading and writer keys are bare base64 pkcs8 with no PEM
 * armour, which the stock ruleset walks straight past.
 */

import { exists, fail, run, section } from "./lib.ts";

const CONFIG = ".gitleaks.toml";

/** Where Homebrew puts it, for the common case of a PATH that lacks it. */
const BREW = "/opt/homebrew/bin/gitleaks";

/**
 * Locate the scanner, or stop.
 *
 * Not skipped when it is missing, the way `fmt` skips swiftformat: a formatter
 * that did not run leaves the code readable, and a secret scan that did not run
 * leaves a green tick over a question nobody asked.
 */
async function locate(): Promise<string> {
  if (await exists(BREW)) return BREW;
  try {
    await new Deno.Command("gitleaks", { args: ["version"], stdout: "null", stderr: "null" })
      .output();
    return "gitleaks";
  } catch {
    fail("gitleaks is not installed — `brew install gitleaks`");
  }
}

export async function scanForSecrets(): Promise<void> {
  const gitleaks = await locate();

  section("Scanning the working directory for secrets");
  await run(gitleaks, { args: ["dir", ".", "--config", CONFIG, "--redact"] });

  section("Scanning history for secrets");
  await run(gitleaks, { args: ["git", ".", "--config", CONFIG, "--redact"] });
}

if (import.meta.main) await scanForSecrets();
