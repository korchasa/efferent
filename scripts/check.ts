/** `deno task check` — everything that must be true before a commit. */

import { checkTooling, run, section } from "./lib.ts";
import { SCHEME, systemToolPath, WORKSPACE } from "./config.ts";
import { generate } from "./generate.ts";
import { scanForSecrets } from "./secrets.ts";
import { checkReader } from "./test-reader.ts";

// First, because it is the one failure a later commit cannot take back.
await scanForSecrets();
await checkTooling();

section("Checking and testing the Python reader");
await checkReader();
await generate();

section("Building for the simulator");
await run("xcodebuild", {
  args: [
    "build",
    "-workspace",
    WORKSPACE,
    "-scheme",
    SCHEME,
    "-configuration",
    "Debug",
    "-destination",
    "generic/platform=iOS Simulator",
    "-quiet",
  ],
  env: systemToolPath(),
});
