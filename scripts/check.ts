/** `deno task check` — everything that must be true before a commit. */

import { checkTooling, run, section } from "./lib.ts";
import { SCHEME, systemToolPath, WORKSPACE } from "./config.ts";
import { generate } from "./generate.ts";

await checkTooling();

section("Testing the protocol, the service and the reading tools");
await run("deno", { args: ["test", "-A", "protocol/", "server/", "tools/"] });
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
