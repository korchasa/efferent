/**
 * `deno task icons` — render the app icons from the committed SVG source.
 *
 * Every slot in `AppIcon.appiconset/Contents.json` is rendered at its own
 * size × scale, the filenames coming from that file rather than from a list
 * here — one place to add a slot, not two. The 1024 slot is the one the App
 * Store shows, and a set without it makes the listing icon come out blank.
 */

import { exists, fail, run, section } from "./lib.ts";

const SOURCE = "documents/icon.svg";
const SET = "Resources/Assets.xcassets/AppIcon.appiconset";

interface Slot {
  size: string;
  scale: string;
  filename?: string;
}

if (!(await exists(SOURCE))) fail(`no icon source at ${SOURCE}`);

const contents = JSON.parse(await Deno.readTextFile(`${SET}/Contents.json`)) as { images: Slot[] };

section(`Rendering ${contents.images.length} icons from ${SOURCE}`);
for (const slot of contents.images) {
  if (!slot.filename) {
    fail(`a slot in ${SET}/Contents.json has no filename: ${JSON.stringify(slot)}`);
  }
  const side = Math.round(Number(slot.size.split("x")[0]) * Number(slot.scale.replace("x", "")));
  await run("rsvg-convert", {
    args: ["-w", String(side), "-h", String(side), SOURCE, "-o", `${SET}/${slot.filename}`],
  });
  console.log(`  ${slot.filename} — ${side}×${side}`);
}
