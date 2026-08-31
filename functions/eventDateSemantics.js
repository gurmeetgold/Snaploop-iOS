const { HttpsError } = require("firebase-functions/https");

const DAY_MS = 24 * 60 * 60 * 1000;
const MAX_EVENT_DAYS = 15;
const DATE_WINDOW_DAYS = 15;
const PHOTO_WINDOW_VERSION = 1;
const BOUNDARY_TOLERANCE_MS = 2;

function invalid(message) {
  throw new HttpsError("invalid-argument", message);
}

function requireMillis(value, name) {
  const n = Number(value);
  if (!Number.isFinite(n)) invalid(`${name} is invalid.`);
  return Math.round(n);
}

function optionalOffsetMinutes(value) {
  if (value === undefined || value === null) return 0;
  const n = Number(value);
  if (!Number.isFinite(n) || n < -14 * 60 || n > 14 * 60) {
    invalid("Timezone offset is invalid.");
  }
  return Math.trunc(n);
}

function localDayNumber(millis, offsetMinutes) {
  return Math.floor((millis + offsetMinutes * 60 * 1000) / DAY_MS);
}

function positiveModulo(value, modulus) {
  return ((value % modulus) + modulus) % modulus;
}

function normalizedTimeZoneId(value) {
  if (typeof value !== "string") invalid("Event timezone is required.");
  const timeZoneId = value.trim();
  if (!timeZoneId || timeZoneId.length > 128) invalid("Event timezone is invalid.");
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: timeZoneId }).format(new Date(0));
  } catch (_) {
    invalid("Event timezone is invalid.");
  }
  return timeZoneId;
}

function timeZoneOffsetMinutes(millis, timeZoneId) {
  const input = new Date(millis);
  const formatter = new Intl.DateTimeFormat("en-US", {
    timeZone: timeZoneId,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  });
  const values = {};
  for (const part of formatter.formatToParts(input)) {
    if (part.type !== "literal") values[part.type] = part.value;
  }
  const reconstructedUTC = Date.UTC(
    Number(values.year),
    Number(values.month) - 1,
    Number(values.day),
    Number(values.hour),
    Number(values.minute),
    Number(values.second)
  );
  const inputToSecond = Math.floor(millis / 1000) * 1000;
  return Math.round((reconstructedUTC - inputToSecond) / (60 * 1000));
}

function verifySuppliedOffset(value, expected) {
  if (value === undefined || value === null) return;
  const supplied = optionalOffsetMinutes(value);
  if (supplied !== expected) invalid("Event timezone offset does not match the selected timezone.");
}

function verifyCanonicalBoundaries(startsAtMillis, endsAtMillis, startOffset, endOffset) {
  const startLocal = positiveModulo(startsAtMillis + startOffset * 60 * 1000, DAY_MS);
  const endLocal = positiveModulo(endsAtMillis + endOffset * 60 * 1000, DAY_MS);

  const startIsMidnight = startLocal <= BOUNDARY_TOLERANCE_MS
    || DAY_MS - startLocal <= BOUNDARY_TOLERANCE_MS;
  const endIsLastMillisecond = Math.abs(endLocal - (DAY_MS - 1)) <= BOUNDARY_TOLERANCE_MS;

  if (!startIsMidnight || !endIsLastMillisecond) {
    invalid("Event photo-window boundaries must cover complete calendar days.");
  }
}

/**
 * Canonical Event date contract shared by create/update handlers.
 *
 * v1 requests represent the user's selected civil days as an inclusive photo
 * window: startsAt is local 00:00:00.000 and endsAt is local 23:59:59.999 in
 * photoWindowTimeZoneId. The server derives timezone offsets itself, validates
 * complete-day boundaries, and evaluates today/±15 using the same timezone.
 *
 * Requests without photoWindowVersion are accepted for installed legacy clients.
 * They retain the old offset-based interpretation but still receive explicit
 * calendar-day duration and ±15 validation. New writes must use v1.
 */
function validateEventDatePayload(data, options = {}) {
  const startsAtMillis = requireMillis(data.startsAtMillis, "startsAt");
  const endsAtMillis = requireMillis(data.endsAtMillis, "endsAt");
  if (endsAtMillis <= startsAtMillis) {
    invalid("Event end date must be after the start date.");
  }

  const nowMillis = Number.isFinite(Number(options.nowMillis))
    ? Math.round(Number(options.nowMillis))
    : Date.now();

  const requestedVersion = Number(data.photoWindowVersion || 0);
  let photoWindowVersion = null;
  let photoWindowTimeZoneId = null;
  let startOffset;
  let endOffset;
  let nowOffset;

  if (requestedVersion === PHOTO_WINDOW_VERSION) {
    photoWindowVersion = PHOTO_WINDOW_VERSION;
    photoWindowTimeZoneId = normalizedTimeZoneId(data.photoWindowTimeZoneId);
    startOffset = timeZoneOffsetMinutes(startsAtMillis, photoWindowTimeZoneId);
    endOffset = timeZoneOffsetMinutes(endsAtMillis, photoWindowTimeZoneId);
    nowOffset = timeZoneOffsetMinutes(nowMillis, photoWindowTimeZoneId);
    verifySuppliedOffset(data.startsAtOffsetMinutes, startOffset);
    verifySuppliedOffset(data.endsAtOffsetMinutes, endOffset);
    verifyCanonicalBoundaries(startsAtMillis, endsAtMillis, startOffset, endOffset);
  } else if (requestedVersion !== 0) {
    invalid("Event photo-window version is unsupported.");
  } else {
    startOffset = optionalOffsetMinutes(data.startsAtOffsetMinutes);
    endOffset = optionalOffsetMinutes(data.endsAtOffsetMinutes);
    nowOffset = optionalOffsetMinutes(data.nowOffsetMinutes);
  }

  const startDay = localDayNumber(startsAtMillis, startOffset);
  const endDay = localDayNumber(endsAtMillis, endOffset);
  if (endDay < startDay) {
    invalid("Event end date must be on or after the start date.");
  }
  if (endDay - startDay > MAX_EVENT_DAYS) {
    invalid(`Events can run for up to ${MAX_EVENT_DAYS} calendar days.`);
  }

  const today = localDayNumber(nowMillis, nowOffset);
  if (
    startDay < today - DATE_WINDOW_DAYS ||
    startDay > today + DATE_WINDOW_DAYS ||
    endDay < today - DATE_WINDOW_DAYS ||
    endDay > today + DATE_WINDOW_DAYS
  ) {
    invalid(
      `Event dates must be within ${DATE_WINDOW_DAYS} days before today and ${DATE_WINDOW_DAYS} days after today.`
    );
  }

  return {
    startsAtMillis,
    endsAtMillis,
    startDay,
    endDay,
    photoWindowVersion,
    photoWindowTimeZoneId,
  };
}

/**
 * Server lifecycle check mirrored by EventLifecycle.graceEnd on iOS. Canonical
 * Events compare civil-day ordinals so a DST transition cannot shorten or extend
 * the recovery period by an hour. Legacy records keep the historical elapsed-ms
 * fallback until their dates are intentionally edited into v1.
 */
function isWithinEventGraceWindow(event, nowMillis = Date.now(), graceDays = 15) {
  const days = Math.max(0, Math.trunc(Number(graceDays) || 0));
  const version = Number(event && event.photoWindowVersion || 0);
  const endDay = Number(event && event.photoWindowEndDayNumber);
  const timeZoneId = event && typeof event.photoWindowTimeZoneId === "string"
    ? event.photoWindowTimeZoneId.trim()
    : "";

  if (version === PHOTO_WINDOW_VERSION && Number.isInteger(endDay) && timeZoneId) {
    const normalizedZone = normalizedTimeZoneId(timeZoneId);
    const nowOffset = timeZoneOffsetMinutes(nowMillis, normalizedZone);
    const nowDay = localDayNumber(nowMillis, nowOffset);
    return nowDay <= endDay + days;
  }

  const endsAtMillis = event && event.endsAt && typeof event.endsAt.toMillis === "function"
    ? event.endsAt.toMillis()
    : Number(event && event.endsAtMillis);
  if (!Number.isFinite(endsAtMillis)) return false;
  return nowMillis <= endsAtMillis + days * DAY_MS;
}

exports.DAY_MS = DAY_MS;
exports.MAX_EVENT_DAYS = MAX_EVENT_DAYS;
exports.DATE_WINDOW_DAYS = DATE_WINDOW_DAYS;
exports.PHOTO_WINDOW_VERSION = PHOTO_WINDOW_VERSION;
exports.localDayNumber = localDayNumber;
exports.timeZoneOffsetMinutes = timeZoneOffsetMinutes;
exports.validateEventDatePayload = validateEventDatePayload;
exports.isWithinEventGraceWindow = isWithinEventGraceWindow;
