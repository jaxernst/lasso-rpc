import assert from "node:assert/strict";
import test from "node:test";
import { RelativeHistogram } from "../relative_histogram.mjs";

test("records, serializes, and merges compatible histograms", () => {
  const left = new RelativeHistogram({
    lowestTrackable: 1,
    highestTrackable: 10_000,
    relativePrecision: 0.01,
  });
  const right = new RelativeHistogram({
    lowestTrackable: 1,
    highestTrackable: 10_000,
    relativePrecision: 0.01,
  });

  for (const value of [1, 10, 100]) left.record(value);
  for (const value of [1_000, 10_000]) right.record(value);
  left.merge(right.serialize());

  const result = left.serialize();
  assert.equal(result.total, 5);
  assert.equal(result.sum, 11_111);
  assert.equal(result.minimum, 1);
  assert.equal(result.maximum, 10_000);
  assert.equal(result.underflow, 0);
  assert.equal(result.overflow, 0);
  assert.ok(result.percentiles.p50 >= 100);
  assert.ok(result.percentiles.p50 <= 101);
  assert.ok(result.percentiles.p95 >= 9_900);
  assert.ok(result.percentiles.p95 <= 10_000);
});

test("counts values outside the configured range", () => {
  const histogram = new RelativeHistogram({
    lowestTrackable: 10,
    highestTrackable: 100,
    relativePrecision: 0.01,
  });

  histogram.record(0);
  histogram.record(101);

  const result = histogram.serialize();
  assert.equal(result.total, 2);
  assert.equal(result.underflow, 1);
  assert.equal(result.overflow, 1);
  assert.equal(result.minimum, 0);
  assert.equal(result.maximum, 101);
});

test("rejects incompatible histogram merges", () => {
  const histogram = new RelativeHistogram({ relativePrecision: 0.01 });
  const incompatible = new RelativeHistogram({ relativePrecision: 0.02 });

  assert.throws(() => histogram.merge(incompatible.serialize()), /incompatible histograms/);
});

test("rejects invalid or overflowing merged buckets", () => {
  const histogram = new RelativeHistogram({
    lowestTrackable: 1,
    highestTrackable: 100,
    relativePrecision: 0.01,
  });
  const serialized = histogram.serialize();

  assert.throws(
    () => histogram.merge({ ...serialized, bins: [[serialized.bucketCount, 1]] }),
    /invalid histogram bucket index/,
  );
  assert.throws(
    () => histogram.merge({ ...serialized, bins: [[0, 0x1_0000_0000]] }),
    /histogram bucket overflow/,
  );
});
