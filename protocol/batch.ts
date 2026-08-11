/**
 * Several sealed days in one request.
 *
 * A day is still the unit of the archive: one object, written whole, replaced
 * whole. This is only about how days travel. The first export is a decade of
 * them, and a request each would be thousands of round trips from a phone that
 * is awake for a couple of seconds at a time — a day is a few kilobytes, so
 * what costs is the request, not what is in it.
 *
 * Each day is sealed on its own, with its own date bound into the tag, before
 * it is packed. The service unpacks the frame and stores the blobs exactly as
 * they arrived, so nothing about the archive changes and a reader cannot tell
 * whether a day travelled alone or with thirty others.
 *
 *     10 bytes  the day, ASCII `YYYY-MM-DD`
 *      4 bytes  how long the sealed blob is, big-endian
 *      n bytes  the sealed blob
 *
 * repeated to the end of the body. There is no count and no header: the body
 * ends where it ends, and anything left over is a truncated frame rather than
 * something to skip.
 *
 * Days ascend and never repeat. That is what makes the frame canonical — the
 * same days in the same versions always pack to the same bytes — and it removes
 * the one question a batch could otherwise ask: which of two copies of a day
 * wins. There is never a second copy.
 */

import { isDay } from "./ids.ts";

/**
 * How many days one request may carry: a month.
 *
 * Not a round number picked for looks. Every day in a batch is a separate write
 * to R2, and a Worker gets a limited number of those per request — fifty on the
 * free plan — so a batch that stored thirty-one days plus the two touches of
 * the writer key sits comfortably inside the smallest budget this can run on.
 * Raising it would work until the day it did not, and would fail halfway
 * through a batch rather than at its edge.
 */
export const MAX_DAYS_PER_REQUEST = 31;

const DAY_BYTES = 10;
const HEADER_BYTES = DAY_BYTES + 4;

export interface SealedDay {
  day: string;
  /** Ciphertext, exactly as it will be stored. Never opened on the way. */
  blob: Uint8Array;
}

export function packDays(days: SealedDay[]): Uint8Array {
  if (days.length === 0) throw new Error("a batch with no days in it");

  let total = 0;
  let previous = "";
  for (const entry of days) {
    check(entry.day, previous, entry.blob.length);
    previous = entry.day;
    total += HEADER_BYTES + entry.blob.length;
  }

  const body = new Uint8Array(total);
  const view = new DataView(body.buffer);
  let offset = 0;
  for (const entry of days) {
    for (let index = 0; index < DAY_BYTES; index++) {
      body[offset + index] = entry.day.charCodeAt(index);
    }
    view.setUint32(offset + DAY_BYTES, entry.blob.length);
    body.set(entry.blob, offset + HEADER_BYTES);
    offset += HEADER_BYTES + entry.blob.length;
  }
  return body;
}

/**
 * Read a frame back, or refuse it.
 *
 * Every way a frame can be wrong throws rather than returning what could be
 * salvaged. A batch that unpacked to the days it happened to parse would store
 * some of what was sent and answer as though it stored all of it — the sender
 * would mark the rest as delivered and never send them again.
 *
 * The blobs are views into `body`, not copies: a frame is a few megabytes and
 * this runs on every upload.
 */
export function unpackDays(body: Uint8Array): SealedDay[] {
  const view = new DataView(body.buffer, body.byteOffset, body.byteLength);
  const decoder = new TextDecoder();
  const days: SealedDay[] = [];
  let offset = 0;
  let previous = "";

  while (offset < body.length) {
    const left = body.length - offset;
    if (left < HEADER_BYTES) throw new Error(`${left} bytes left over where a day was expected`);

    const day = decoder.decode(body.subarray(offset, offset + DAY_BYTES));
    const length = view.getUint32(offset + DAY_BYTES);
    check(day, previous, length);
    if (left - HEADER_BYTES < length) {
      throw new Error(`${day} says ${length} bytes and only ${left - HEADER_BYTES} are there`);
    }

    days.push({ day, blob: body.subarray(offset + HEADER_BYTES, offset + HEADER_BYTES + length) });
    previous = day;
    offset += HEADER_BYTES + length;
  }

  if (days.length === 0) throw new Error("a batch with no days in it");
  return days;
}

function check(day: string, previous: string, length: number): void {
  if (!isDay(day)) throw new Error(`${JSON.stringify(day)} is not a day`);
  if (day <= previous) throw new Error(`days must ascend without repeats: ${previous} then ${day}`);
  if (length === 0) throw new Error(`${day} carries no body`);
}
