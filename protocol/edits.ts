/**
 * What an agent may ask the phone to write into Health, and what the phone
 * says happened.
 *
 * An edit is a list of items. A `put` adds a sample or replaces the one this
 * app wrote earlier under the same id; a `delete` removes that sample. The id
 * is the agent's handle: the phone turns it into a HealthKit sync identifier,
 * keeps a version per id, and HealthKit replaces the sample atomically when a
 * higher version arrives. That is what makes applying the same edit twice —
 * after a crash before the phone could say so — end with one sample, not two.
 *
 * Only samples this app wrote can be replaced or removed. Sleep from a watch,
 * a meal logged by another app, steps from the phone itself are Health's and
 * stay Health's; an item that names one is refused with a code, never quietly
 * skipped.
 *
 * This file is the plaintext inside the sealed edit. The service never parses
 * it, and the codes in an outcome are the whole of what the service learns
 * about what was in one: an index and a word, never a metric or a value.
 */

import { compress, decompress } from "./framing.ts";

export const EDIT_FORMAT_VERSION = 1;
/** Items per edit. A day of meals is a handful; a month of corrections is a few hundred. */
export const MAX_ITEMS_PER_EDIT = 500;
/** What plaintext an edit may inflate to. 500 items are well under 100 KB. */
export const MAX_EDIT_PLAINTEXT_BYTES = 1024 * 1024;

const ID = /^[A-Za-z0-9._:-]{1,120}$/;

export const SLEEP_STAGES = [
  "inBed",
  "awake",
  "asleepUnspecified",
  "asleepCore",
  "asleepDeep",
  "asleepREM",
] as const;
export type SleepStage = typeof SLEEP_STAGES[number];

export type WritableKind =
  | { kind: "quantity"; unit: string }
  | { kind: "category"; stages: readonly SleepStage[] };

/**
 * The catalogue of what can be written, and in which unit. Every name here is
 * also a name the phone reads, so an edit shows up in the archive afterwards.
 */
export const WRITABLE: Readonly<Record<string, WritableKind>> = {
  sleep: { kind: "category", stages: SLEEP_STAGES },
  dietaryEnergy: { kind: "quantity", unit: "kcal" },
  dietaryProtein: { kind: "quantity", unit: "g" },
  dietaryCarbohydrates: { kind: "quantity", unit: "g" },
  dietaryFat: { kind: "quantity", unit: "g" },
  dietaryWater: { kind: "quantity", unit: "mL" },
  bodyMass: { kind: "quantity", unit: "kg" },
};

export interface PutItem {
  op: "put";
  id: string;
  metric: string;
  /** Whole seconds since 1970, both ends. */
  start: number;
  end: number;
  value?: number;
  unit?: string;
  stage?: SleepStage;
}

export interface DeleteItem {
  op: "delete";
  id: string;
}

export type EditItem = PutItem | DeleteItem;

/** The words the phone may answer with. A word outside this set is `malformed`. */
export const OUTCOME_CODES = [
  "unknownMetric",
  "badUnit",
  "badRange",
  "unauthorized",
  "notFound",
  "healthRefused",
  "badSignature",
  "cannotOpen",
  "malformed",
] as const;
export type OutcomeCode = typeof OUTCOME_CODES[number];

export interface Outcome {
  applied: number;
  refused: { item: number; code: OutcomeCode }[];
}

const PUT_KEYS = ["op", "id", "metric", "start", "end", "value", "unit", "stage"];
const DELETE_KEYS = ["op", "id"];

/** Every way an item can be wrong throws, naming the field. */
export function validateItems(items: unknown): asserts items is EditItem[] {
  if (!Array.isArray(items)) throw new Error("items must be a list");
  if (items.length === 0) throw new Error("an edit with no items in it");
  if (items.length > MAX_ITEMS_PER_EDIT) {
    throw new Error(`an edit may carry ${MAX_ITEMS_PER_EDIT} items, not ${items.length}`);
  }
  items.forEach((item, index) => {
    try {
      validateItem(item);
    } catch (error) {
      throw new Error(`item ${index}: ${(error as Error).message}`);
    }
  });
}

function validateItem(item: unknown): asserts item is EditItem {
  if (typeof item !== "object" || item === null || Array.isArray(item)) {
    throw new Error("an item must be an object");
  }
  const record = item as Record<string, unknown>;
  if (record.op !== "put" && record.op !== "delete") {
    throw new Error(`op must be put or delete, not ${JSON.stringify(record.op)}`);
  }
  if (typeof record.id !== "string" || !ID.test(record.id)) {
    throw new Error("id must be 1 to 120 characters of letters, digits, . _ : -");
  }
  const allowed = record.op === "put" ? PUT_KEYS : DELETE_KEYS;
  for (const key of Object.keys(record)) {
    if (!allowed.includes(key)) throw new Error(`${key} is not a field of a ${record.op} item`);
  }
  if (record.op === "delete") return;

  if (typeof record.metric !== "string" || !(record.metric in WRITABLE)) {
    throw new Error(`metric ${JSON.stringify(record.metric)} cannot be written`);
  }
  const shape = WRITABLE[record.metric];
  if (!isInstant(record.start)) throw new Error("start must be whole seconds since 1970");
  if (!isInstant(record.end)) throw new Error("end must be whole seconds since 1970");
  if ((record.end as number) < (record.start as number)) {
    throw new Error("end must not be before start");
  }
  if (shape.kind === "quantity") {
    if ("stage" in record) throw new Error("stage belongs to sleep, not to a quantity");
    if (typeof record.value !== "number" || !Number.isFinite(record.value) || record.value < 0) {
      throw new Error("value must be a finite number, zero or more");
    }
    if (record.unit !== shape.unit) {
      throw new Error(`unit must be ${shape.unit} for ${record.metric}`);
    }
  } else {
    if ("value" in record || "unit" in record) {
      throw new Error("value and unit belong to a quantity, not to sleep");
    }
    if (typeof record.stage !== "string" || !shape.stages.includes(record.stage as SleepStage)) {
      throw new Error(`stage must be one of ${shape.stages.join(", ")}`);
    }
  }
}

function isInstant(value: unknown): boolean {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

/**
 * Raw-deflate-compressed `{"v":1,"items":[…]}`, keys in a fixed order, so the
 * same items always pack to the same bytes.
 */
export async function packEdits(items: EditItem[]): Promise<Uint8Array> {
  validateItems(items);
  const ordered = items.map((item) =>
    item.op === "put"
      ? pick(item, PUT_KEYS as (keyof PutItem)[])
      : pick(item, DELETE_KEYS as (keyof DeleteItem)[])
  );
  const text = JSON.stringify({ v: EDIT_FORMAT_VERSION, items: ordered });
  return await compress(new TextEncoder().encode(text));
}

export async function unpackEdits(bytes: Uint8Array): Promise<EditItem[]> {
  const plaintext = await decompress(bytes);
  if (plaintext.length > MAX_EDIT_PLAINTEXT_BYTES) {
    throw new Error(`an edit inflated past ${MAX_EDIT_PLAINTEXT_BYTES} bytes`);
  }
  const parsed: unknown = JSON.parse(new TextDecoder().decode(plaintext));
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error("an edit must be one object");
  }
  const record = parsed as Record<string, unknown>;
  for (const key of Object.keys(record)) {
    if (key !== "v" && key !== "items") throw new Error(`${key} is not a field of an edit`);
  }
  if (record.v !== EDIT_FORMAT_VERSION) {
    throw new Error(
      `edit format version ${JSON.stringify(record.v)} is not one this reader speaks`,
    );
  }
  validateItems(record.items);
  return record.items;
}

/** The bucket is bound into the ciphertext; the name is given later, by the service. */
export function editAssociatedData(bucket: string): Uint8Array {
  return new TextEncoder().encode(`efferent/v1 edit\n${bucket}`);
}

export function validateOutcome(value: unknown): asserts value is Outcome {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error("an outcome must be an object");
  }
  const record = value as Record<string, unknown>;
  for (const key of Object.keys(record)) {
    if (key !== "applied" && key !== "refused") {
      throw new Error(`${key} is not a field of an outcome`);
    }
  }
  if (!Number.isSafeInteger(record.applied) || (record.applied as number) < 0) {
    throw new Error("applied must be a count");
  }
  if (!Array.isArray(record.refused)) throw new Error("refused must be a list");
  for (const entry of record.refused) {
    if (typeof entry !== "object" || entry === null) throw new Error("a refusal must be an object");
    const refusal = entry as Record<string, unknown>;
    for (const key of Object.keys(refusal)) {
      if (key !== "item" && key !== "code") throw new Error(`${key} is not a field of a refusal`);
    }
    if (!Number.isSafeInteger(refusal.item) || (refusal.item as number) < 0) {
      throw new Error("item must be an index");
    }
    if (!OUTCOME_CODES.includes(refusal.code as OutcomeCode)) {
      throw new Error(`code ${JSON.stringify(refusal.code)} is not one the protocol knows`);
    }
  }
}

function pick<T extends object>(item: T, keys: (keyof T)[]): Partial<T> {
  const out: Partial<T> = {};
  for (const key of keys) {
    if (key in item && item[key] !== undefined) out[key] = item[key];
  }
  return out;
}
