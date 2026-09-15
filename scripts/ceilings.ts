/**
 * How much of the service-wide ceiling has been handed over.
 *
 * `MAX_SERVICE_BYTES` counts bytes ever given to the service and never comes
 * down. When it runs out every upload from every phone is answered `507`, and
 * nothing in the service says a word before that happens. So the warning has to
 * come from outside, and this is the cheap outside look: one known object read
 * straight out of R2, no Worker to start, nothing to leave running. It exits
 * non-zero above the threshold, so a scheduler can act on it.
 *
 *   deno task ceilings            # warn at 80%
 *   deno task ceilings --warn 50  # warn earlier
 *
 * It answers about the service and nothing else. Per-archive tallies need a
 * listing, R2 gives a listing only to code running inside a Worker, and that is
 * `server/maintenance` — which answers this question as well, in more detail,
 * for a person who is already looking. This one exists for the times nobody is.
 *
 * The ceiling is imported rather than written down again: two copies of the
 * number that decides when uploads stop is how a check ends up reassuring
 * somebody about a limit that moved.
 */

import { SERVICE_TAKEN_OBJECT } from "../protocol/ids.ts";
import { MAX_SERVICE_BYTES, SERVICE_BYTES_ALREADY_TAKEN } from "../server/src/index.ts";
import { fail, run, section } from "./lib.ts";

/** The live bucket, as `server/wrangler.jsonc` binds it. */
const BUCKET = "efferent";

function threshold(args: string[]): number {
  const at = args.indexOf("--warn");
  if (at === -1) return 80;
  const value = Number(args[at + 1]);
  if (!Number.isFinite(value) || value <= 0 || value > 100) {
    fail(`--warn takes a percentage between 0 and 100, not ${args[at + 1]}`);
  }
  return value;
}

function mib(bytes: number): string {
  return `${(bytes / (1024 * 1024)).toFixed(1)} MiB`;
}

/**
 * The tally as R2 holds it. An absent object is not zero: the service starts
 * counting from what it had already been handed when the ceiling was added.
 */
async function serviceTaken(): Promise<number> {
  const file = await Deno.makeTempFile({ prefix: "efferent-taken-" });
  try {
    const result = await run("npx", {
      args: [
        "wrangler",
        "r2",
        "object",
        "get",
        `${BUCKET}/${SERVICE_TAKEN_OBJECT}`,
        "--remote",
        "--file",
        file,
      ],
      capture: true,
      allowFailure: true,
      env: { ...Deno.env.toObject(), NO_COLOR: "1" },
    });
    if (result.code !== 0) {
      if (/not found|does not exist|404/i.test(`${result.stdout}${result.stderr}`)) {
        return SERVICE_BYTES_ALREADY_TAKEN;
      }
      console.error(result.stdout || result.stderr);
      fail(
        `could not read ${BUCKET}/${SERVICE_TAKEN_OBJECT}; is this machine logged in to wrangler?`,
      );
    }
    const counted = Number((await Deno.readTextFile(file)).trim());
    if (!Number.isSafeInteger(counted) || counted < 0) {
      fail(`${BUCKET}/${SERVICE_TAKEN_OBJECT} does not hold a byte count`);
    }
    return counted;
  } finally {
    await Deno.remove(file).catch(() => {});
  }
}

const warnAt = threshold(Deno.args);
section("service ceiling");
const taken = await serviceTaken();
const used = (taken / MAX_SERVICE_BYTES) * 100;
console.log(`handed over : ${mib(taken)} (${taken} bytes)`);
console.log(`ceiling     : ${mib(MAX_SERVICE_BYTES)}`);
console.log(`used        : ${used.toFixed(2)}%`);
console.log(`left        : ${mib(MAX_SERVICE_BYTES - taken)}`);

if (used >= warnAt) {
  console.error(
    `\nwarning: ${
      used.toFixed(2)
    }% of the service ceiling has been handed over, past the ${warnAt}% mark.\n` +
      `Every upload is answered 507 when it runs out. Raise MAX_SERVICE_BYTES in server/src/index.ts and\n` +
      `deploy, or look at what is taking it with server/maintenance.`,
  );
  Deno.exit(1);
}
console.log(`\nunder the ${warnAt}% mark.`);
