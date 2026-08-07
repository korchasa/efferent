/**
 * `deno task dist` — UNSIGNED App Store archive.
 *
 * Signing, packaging and upload all happen outside this repository; nothing
 * here touches a certificate. The output path is part of that contract and must
 * stay exactly `build/Efferent.xcarchive`.
 */

import { exists, fail, run, section } from "./lib.ts";
import { ARCHIVE, SCHEME, systemToolPath, WORKSPACE } from "./config.ts";
import { generate } from "./generate.ts";

await generate();

section("Archiving for the App Store (unsigned)");
await Deno.remove(ARCHIVE, { recursive: true }).catch(() => {});
await run("xcodebuild", {
  args: [
    "archive",
    "-workspace",
    WORKSPACE,
    "-scheme",
    SCHEME,
    "-configuration",
    "Release",
    "-destination",
    "generic/platform=iOS",
    "-archivePath",
    ARCHIVE,
    "CODE_SIGNING_ALLOWED=NO",
    "CODE_SIGNING_REQUIRED=NO",
    "CODE_SIGN_STYLE=Manual",
    "CODE_SIGN_IDENTITY=",
    "-quiet",
  ],
  env: systemToolPath(),
});

if (!(await exists(ARCHIVE))) fail(`archive was not produced at ${ARCHIVE}`);
section(`Unsigned archive: ${ARCHIVE}`);
