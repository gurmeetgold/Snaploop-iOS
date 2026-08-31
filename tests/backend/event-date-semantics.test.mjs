import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const {
  PHOTO_WINDOW_VERSION,
  localDayNumber,
  timeZoneOffsetMinutes,
  validateEventDatePayload,
} = require("../../functions/eventDateSemantics.js");

function millis(iso) {
  return Date.parse(iso);
}

function canonicalPayload({ start, end, zone = "UTC", startOffset, endOffset }) {
  const payload = {
    photoWindowVersion: PHOTO_WINDOW_VERSION,
    photoWindowTimeZoneId: zone,
    startsAtMillis: millis(start),
    endsAtMillis: millis(end),
  };
  if (startOffset !== undefined) payload.startsAtOffsetMinutes = startOffset;
  if (endOffset !== undefined) payload.endsAtOffsetMinutes = endOffset;
  return payload;
}

test("spring DST: fifteen civil-day distance is accepted without elapsed-hour assumptions", () => {
  const payload = canonicalPayload({
    zone: "America/Toronto",
    start: "2026-03-01T05:00:00.000Z", // Mar 1 00:00 EST
    end: "2026-03-17T03:59:59.999Z",   // Mar 16 23:59:59.999 EDT
    startOffset: -300,
    endOffset: -240,
  });

  const result = validateEventDatePayload(payload, {
    nowMillis: millis("2026-03-10T16:00:00.000Z"), // Mar 10 noon EDT
  });

  assert.equal(result.endDay - result.startDay, 15);
  assert.equal(result.photoWindowTimeZoneId, "America/Toronto");
  // Inclusive whole-day bounds cover 16 selected date labels when the start/end
  // civil-day ordinal distance is 15. Spring DST removes one elapsed hour.
  assert.equal(payload.endsAtMillis - payload.startsAtMillis, (383 * 60 * 60 * 1000) - 1);
});

test("fall DST: fifteen civil-day distance is accepted without elapsed-hour assumptions", () => {
  const payload = canonicalPayload({
    zone: "America/Toronto",
    start: "2026-10-25T04:00:00.000Z", // Oct 25 00:00 EDT
    end: "2026-11-10T04:59:59.999Z",   // Nov 9 23:59:59.999 EST
    startOffset: -240,
    endOffset: -300,
  });

  const result = validateEventDatePayload(payload, {
    nowMillis: millis("2026-11-01T17:00:00.000Z"),
  });

  assert.equal(result.endDay - result.startDay, 15);
  // Fall DST adds one elapsed hour to the same civil-day span.
  assert.equal(payload.endsAtMillis - payload.startsAtMillis, (385 * 60 * 60 * 1000) - 1);
});

test("civil day numbers advance by one across Toronto spring and fall DST", () => {
  const zone = "America/Toronto";

  const springBefore = millis("2026-03-08T05:00:00.000Z"); // Mar 8 00:00 EST
  const springAfter = millis("2026-03-09T04:00:00.000Z");  // Mar 9 00:00 EDT
  assert.equal(springAfter - springBefore, 23 * 60 * 60 * 1000);
  assert.equal(
    localDayNumber(springAfter, timeZoneOffsetMinutes(springAfter, zone))
      - localDayNumber(springBefore, timeZoneOffsetMinutes(springBefore, zone)),
    1
  );

  const fallBefore = millis("2026-11-01T04:00:00.000Z"); // Nov 1 00:00 EDT
  const fallAfter = millis("2026-11-02T05:00:00.000Z");  // Nov 2 00:00 EST
  assert.equal(fallAfter - fallBefore, 25 * 60 * 60 * 1000);
  assert.equal(
    localDayNumber(fallAfter, timeZoneOffsetMinutes(fallAfter, zone))
      - localDayNumber(fallBefore, timeZoneOffsetMinutes(fallBefore, zone)),
    1
  );
});

test("same civil-day Event is valid and covers a complete day", () => {
  const payload = canonicalPayload({
    start: "2026-08-16T00:00:00.000Z",
    end: "2026-08-16T23:59:59.999Z",
  });
  const result = validateEventDatePayload(payload, {
    nowMillis: millis("2026-08-16T12:00:00.000Z"),
  });
  assert.equal(result.startDay, result.endDay);
});

test("legacy compatibility still rejects reversed timestamps within one civil day", () => {
  assert.throws(() => validateEventDatePayload({
    startsAtMillis: millis("2026-08-16T20:00:00.000Z"),
    endsAtMillis: millis("2026-08-16T08:00:00.000Z"),
    startsAtOffsetMinutes: 0,
    endsAtOffsetMinutes: 0,
    nowOffsetMinutes: 0,
  }, { nowMillis: millis("2026-08-16T12:00:00.000Z") }));
});

test("plus/minus fifteen-day today boundary is inclusive", () => {
  const nowMillis = millis("2026-08-16T12:00:00.000Z");

  assert.doesNotThrow(() => validateEventDatePayload(canonicalPayload({
    start: "2026-08-01T00:00:00.000Z",
    end: "2026-08-16T23:59:59.999Z",
  }), { nowMillis }));

  assert.doesNotThrow(() => validateEventDatePayload(canonicalPayload({
    start: "2026-08-16T00:00:00.000Z",
    end: "2026-08-31T23:59:59.999Z",
  }), { nowMillis }));
});

test("sixteen days before or after today is rejected independently of duration", () => {
  const nowMillis = millis("2026-08-16T12:00:00.000Z");

  assert.throws(() => validateEventDatePayload(canonicalPayload({
    start: "2026-07-31T00:00:00.000Z",
    end: "2026-08-02T23:59:59.999Z",
  }), { nowMillis }));

  assert.throws(() => validateEventDatePayload(canonicalPayload({
    start: "2026-08-30T00:00:00.000Z",
    end: "2026-09-01T23:59:59.999Z",
  }), { nowMillis }));
});

test("sixteen civil-day duration is rejected", () => {
  assert.throws(() => validateEventDatePayload(canonicalPayload({
    start: "2026-08-01T00:00:00.000Z",
    end: "2026-08-17T23:59:59.999Z",
  }), { nowMillis: millis("2026-08-10T12:00:00.000Z") }));
});

test("v1 rejects hidden-time boundaries instead of silently broadening them", () => {
  assert.throws(() => validateEventDatePayload(canonicalPayload({
    start: "2026-08-16T12:00:00.000Z",
    end: "2026-08-16T23:59:59.999Z",
  }), { nowMillis: millis("2026-08-16T12:00:00.000Z") }));
});

test("v1 rejects a client-supplied offset that disagrees with its IANA timezone", () => {
  assert.throws(() => validateEventDatePayload(canonicalPayload({
    zone: "America/Toronto",
    start: "2026-08-16T04:00:00.000Z",
    end: "2026-08-17T03:59:59.999Z",
    startOffset: -300,
    endOffset: -240,
  }), { nowMillis: millis("2026-08-16T16:00:00.000Z") }));
});

test("unsupported photo-window versions fail closed", () => {
  assert.throws(() => validateEventDatePayload({
    photoWindowVersion: 999,
    photoWindowTimeZoneId: "UTC",
    startsAtMillis: millis("2026-08-16T00:00:00.000Z"),
    endsAtMillis: millis("2026-08-16T23:59:59.999Z"),
  }, { nowMillis: millis("2026-08-16T12:00:00.000Z") }));
});
