import { assert, assertEquals, assertRejects, assertThrows } from "@std/assert";

import {
  editKey,
  editorKeyObject,
  editPrefix,
  isEditName,
  newEditName,
  outcomeKey,
  outcomePrefix,
} from "./ids.ts";
import {
  editAssociatedData,
  type EditItem,
  MAX_ITEMS_PER_EDIT,
  OUTCOME_CODES,
  packEdits,
  unpackEdits,
  validateItems,
  validateOutcome,
  WRITABLE,
} from "./edits.ts";
import {
  base64url,
  canonicalEdit,
  canonicalEditorRegistration,
  canonicalFetch,
  canonicalOutcome,
  signMessage,
  verifyMessage,
} from "./signing.ts";

const encoder = new TextEncoder();

async function editorKeys(): Promise<{ privateKey: CryptoKey; publicRaw: Uint8Array }> {
  const pair = await crypto.subtle.generateKey({ name: "Ed25519" }, true, [
    "sign",
    "verify",
  ]) as CryptoKeyPair;
  return {
    privateKey: pair.privateKey,
    publicRaw: new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey)),
  };
}

const BUCKET = "abcdefghijklmnopqrstuvwxyz";

const meal: EditItem[] = [
  {
    op: "put",
    id: "agent:meal:2026-09-07:breakfast",
    metric: "dietaryEnergy",
    start: 1757228400,
    end: 1757229300,
    value: 520,
    unit: "kcal",
  },
  {
    op: "put",
    id: "agent:sleep:2026-09-06:core",
    metric: "sleep",
    start: 1757196000,
    end: 1757221200,
    stage: "asleepCore",
  },
  { op: "delete", id: "agent:meal:2026-09-01:lunch" },
];

// MARK: - Names and keys

Deno.test("edit objects live under e/ and outcomes under o/, apart from the days", () => {
  assertEquals(editorKeyObject(BUCKET), `${BUCKET}/editor`);
  assertEquals(editPrefix(BUCKET), `${BUCKET}/e/`);
  assertEquals(outcomePrefix(BUCKET), `${BUCKET}/o/`);
  assertEquals(editKey(BUCKET, "1757228400000-abcdefgh"), `${BUCKET}/e/1757228400000-abcdefgh`);
  assertEquals(outcomeKey(BUCKET, "1757228400000-abcdefgh"), `${BUCKET}/o/1757228400000-abcdefgh`);
});

Deno.test("an edit name is thirteen digits of milliseconds and eight base32 characters", () => {
  const name = newEditName(1757228400000, Uint8Array.from([1, 2, 3, 4, 5]));
  assert(isEditName(name), name);
  assert(name.startsWith("1757228400000-"));
  assertEquals(name.length, 13 + 1 + 8);
  assert(!isEditName("1757228400000-ABCDEFGH"), "upper case is not base32 here");
  assert(!isEditName("175722840000-abcdefgh"), "twelve digits");
  assert(!isEditName("1757228400000-abcdefg"), "seven characters");
  assert(!isEditName("../1757228400000-abcdefgh"));
});

Deno.test("edit names sort in the order they were made", () => {
  const earlier = newEditName(1757228400000, Uint8Array.from([255, 255, 255, 255, 255]));
  const later = newEditName(1757228400001, Uint8Array.from([0, 0, 0, 0, 0]));
  assert(earlier < later);
});

Deno.test("a name needs exactly five random bytes", () => {
  assertThrows(() => newEditName(1757228400000, Uint8Array.from([1, 2, 3, 4])));
  assertThrows(() => newEditName(-1, Uint8Array.from([1, 2, 3, 4, 5])));
});

// MARK: - Items

Deno.test("a batch of items survives a round trip", async () => {
  const bytes = await packEdits(meal);
  assertEquals(await unpackEdits(bytes), meal);
});

Deno.test("the same items always pack to the same bytes", async () => {
  const reordered: EditItem[] = [
    {
      unit: "kcal",
      value: 520,
      end: 1757229300,
      start: 1757228400,
      metric: "dietaryEnergy",
      id: "agent:meal:2026-09-07:breakfast",
      op: "put",
    } as EditItem,
    meal[1],
    meal[2],
  ];
  assertEquals(await packEdits(meal), await packEdits(reordered));
});

Deno.test("the catalogue names what can be written and in which unit", () => {
  assertEquals(WRITABLE.sleep, {
    kind: "category",
    stages: [
      "inBed",
      "awake",
      "asleepUnspecified",
      "asleepCore",
      "asleepDeep",
      "asleepREM",
    ],
  });
  assertEquals(WRITABLE.dietaryEnergy, { kind: "quantity", unit: "kcal" });
  assertEquals(WRITABLE.dietaryProtein, { kind: "quantity", unit: "g" });
  assertEquals(WRITABLE.dietaryCarbohydrates, { kind: "quantity", unit: "g" });
  assertEquals(WRITABLE.dietaryFat, { kind: "quantity", unit: "g" });
  assertEquals(WRITABLE.dietaryWater, { kind: "quantity", unit: "mL" });
  assertEquals(WRITABLE.bodyMass, { kind: "quantity", unit: "kg" });
});

Deno.test("an item is refused for every way it can be wrong", () => {
  const bad: [unknown, string][] = [
    [{ op: "put", id: "a", metric: "steps", start: 1, end: 2, value: 1, unit: "count" }, "metric"],
    [
      { op: "put", id: "a", metric: "dietaryFat", start: 1, end: 2, value: 1, unit: "kcal" },
      "unit",
    ],
    [{ op: "put", id: "a", metric: "dietaryFat", start: 5, end: 2, value: 1, unit: "g" }, "end"],
    [{ op: "put", id: "a", metric: "dietaryFat", start: 1, end: 2, value: -1, unit: "g" }, "value"],
    [{ op: "put", id: "a", metric: "sleep", start: 1, end: 2, stage: "asleep" }, "stage"],
    [{ op: "put", id: "a", metric: "sleep", start: 1, end: 2, stage: "awake", value: 1 }, "value"],
    [
      { op: "put", id: "a", metric: "dietaryFat", start: 1, end: 2, value: 1, unit: "g", note: 1 },
      "note",
    ],
    [{ op: "put", id: "a b", metric: "dietaryFat", start: 1, end: 2, value: 1, unit: "g" }, "id"],
    [{
      op: "put",
      id: "a".repeat(121),
      metric: "dietaryFat",
      start: 1,
      end: 2,
      value: 1,
      unit: "g",
    }, "id"],
    [
      { op: "put", id: "a", metric: "dietaryFat", start: 1.5, end: 2, value: 1, unit: "g" },
      "start",
    ],
    [{ op: "delete", id: "a", metric: "dietaryFat" }, "metric"],
    [{ op: "merge", id: "a" }, "op"],
    ["not an object", "item"],
  ];
  for (const [item, word] of bad) {
    const error = assertThrows(() => validateItems([item as EditItem]), Error);
    assert(error.message.includes(word), `${JSON.stringify(item)}: ${error.message}`);
  }
});

Deno.test("a batch has a size, and an empty one is not a batch", () => {
  assertThrows(() => validateItems([]), Error, "no items");
  const many = Array.from({ length: MAX_ITEMS_PER_EDIT + 1 }, (_, index) => ({
    op: "delete" as const,
    id: `id-${index}`,
  }));
  assertThrows(() => validateItems(many), Error, String(MAX_ITEMS_PER_EDIT));
});

Deno.test("a batch from another format version is refused", async () => {
  const { compress } = await import("./framing.ts");
  const other = await compress(encoder.encode(JSON.stringify({ v: 2, items: [] })));
  await assertRejects(() => unpackEdits(other), Error, "version");
  const garbage = await compress(encoder.encode("[1,2"));
  await assertRejects(() => unpackEdits(garbage), Error);
  const unknownKey = await compress(
    encoder.encode(JSON.stringify({ v: 1, items: [{ op: "delete", id: "a" }], extra: true })),
  );
  await assertRejects(() => unpackEdits(unknownKey), Error, "extra");
});

Deno.test("associated data binds an edit to its bucket", () => {
  assertEquals(
    new TextDecoder().decode(editAssociatedData(BUCKET)),
    `efferent/v1 edit\n${BUCKET}`,
  );
});

// MARK: - Outcomes

Deno.test("an outcome carries counts and codes and nothing else", () => {
  validateOutcome({ applied: 2, refused: [{ item: 1, code: "badRange" }] });
  validateOutcome({ applied: 0, refused: [] });
  assertThrows(() => validateOutcome({ applied: -1, refused: [] }), Error, "applied");
  assertThrows(
    () => validateOutcome({ applied: 1, refused: [{ item: 0, code: "steps" }] }),
    Error,
    "code",
  );
  assertThrows(
    () => validateOutcome({ applied: 1, refused: [{ item: -1, code: "badRange" }] }),
    Error,
    "item",
  );
  assertThrows(
    () => validateOutcome({ applied: 1, refused: [{ item: 0, code: "badRange", metric: "x" }] }),
    Error,
    "metric",
  );
  assertThrows(() => validateOutcome({ applied: 1 }), Error, "refused");
  assertThrows(() => validateOutcome({ applied: 1, refused: [], note: "x" }), Error, "note");
  assert(OUTCOME_CODES.includes("unauthorized"));
  assert(OUTCOME_CODES.includes("badSignature"));
});

// MARK: - Signatures

Deno.test("each canonical message says what it is for, byte for byte", async () => {
  const body = encoder.encode("hello");
  const digest = "LPJNul-wow4m6DsqxbninhsWHlwfp0JecwQzYpOLmCQ";
  assertEquals(
    await canonicalEditorRegistration(BUCKET, 1700000000, body),
    `efferent/v1 editor\n${BUCKET}\n1700000000\n${digest}`,
  );
  assertEquals(
    await canonicalEdit(BUCKET, 1700000000, body),
    `efferent/v1 edit\n${BUCKET}\n1700000000\n${digest}`,
  );
  assertEquals(
    await canonicalOutcome(BUCKET, "1757228400000-abcdefgh", 1700000000, body),
    `efferent/v1 outcome\n${BUCKET}\n1757228400000-abcdefgh\n1700000000\n${digest}`,
  );
  assertEquals(
    canonicalFetch(BUCKET, "1757228400000-abcdefgh", 1700000000),
    `efferent/v1 fetch\n${BUCKET}\n1757228400000-abcdefgh\n1700000000`,
  );
});

Deno.test("a message signed by the editor verifies, and nothing else does", async () => {
  const editor = await editorKeys();
  const other = await editorKeys();
  const sealed = encoder.encode("sealed bytes");
  const message = await canonicalEdit(BUCKET, 1700000000, sealed);
  const signature = await signMessage(editor.privateKey, message);
  assertEquals(signature.length, 64);
  assert(await verifyMessage(editor.publicRaw, signature, message));
  assert(!await verifyMessage(other.publicRaw, signature, message));
  assert(!await verifyMessage(editor.publicRaw, signature, message + "x"));
  assert(!await verifyMessage(new Uint8Array(32), new Uint8Array(64), message), "small order");
  assert(!await verifyMessage(editor.publicRaw, signature.subarray(1), message), "wrong length");
  assertEquals(base64url(signature).length, 86);
});
