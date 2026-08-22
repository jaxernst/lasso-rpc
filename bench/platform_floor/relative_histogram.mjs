const defaults = {
  lowestTrackable: 1,
  highestTrackable: 60_000_000,
  relativePrecision: 0.001,
};

export class RelativeHistogram {
  constructor(options = {}) {
    this.lowestTrackable = options.lowestTrackable ?? defaults.lowestTrackable;
    this.highestTrackable = options.highestTrackable ?? defaults.highestTrackable;
    this.relativePrecision = options.relativePrecision ?? defaults.relativePrecision;
    if (!(this.lowestTrackable > 0) || this.highestTrackable <= this.lowestTrackable) {
      throw new Error("invalid histogram range");
    }
    if (!(this.relativePrecision > 0 && this.relativePrecision < 1)) {
      throw new Error("relativePrecision must be in (0, 1)");
    }

    this.logRatio = Math.log1p(this.relativePrecision);
    this.bucketCount = Math.ceil(
      Math.log(this.highestTrackable / this.lowestTrackable) / this.logRatio,
    ) + 1;
    this.counts = new Uint32Array(this.bucketCount);
    this.total = 0;
    this.sum = 0;
    this.minimum = Infinity;
    this.maximum = 0;
    this.underflow = 0;
    this.overflow = 0;
  }

  record(value) {
    if (!Number.isFinite(value) || value < 0) throw new Error("invalid histogram value");
    if (value < this.lowestTrackable) this.underflow += 1;
    if (value > this.highestTrackable) this.overflow += 1;
    const bounded = Math.min(this.highestTrackable, Math.max(this.lowestTrackable, value));
    const index = Math.min(
      this.bucketCount - 1,
      Math.max(0, Math.floor(Math.log(bounded / this.lowestTrackable) / this.logRatio)),
    );
    if (this.counts[index] === 0xffffffff) throw new Error("histogram bucket overflow");
    this.counts[index] += 1;
    this.total += 1;
    this.sum += value;
    this.minimum = Math.min(this.minimum, value);
    this.maximum = Math.max(this.maximum, value);
  }

  merge(serialized) {
    if (
      serialized.bucketCount !== this.bucketCount ||
      serialized.lowestTrackable !== this.lowestTrackable ||
      serialized.highestTrackable !== this.highestTrackable ||
      serialized.relativePrecision !== this.relativePrecision
    ) throw new Error("incompatible histograms");

    for (const [index, count] of serialized.bins) {
      if (!Number.isSafeInteger(index) || index < 0 || index >= this.bucketCount) {
        throw new Error("invalid histogram bucket index");
      }
      if (!Number.isSafeInteger(count) || count < 0 || this.counts[index] + count > 0xffffffff) {
        throw new Error("histogram bucket overflow");
      }
      this.counts[index] += count;
    }
    this.total += serialized.total;
    this.sum += serialized.sum;
    this.underflow += serialized.underflow;
    this.overflow += serialized.overflow;
    if (serialized.total > 0) {
      this.minimum = Math.min(this.minimum, serialized.minimum);
      this.maximum = Math.max(this.maximum, serialized.maximum);
    }
  }

  percentile(fraction) {
    if (this.total === 0) return null;
    const target = Math.ceil(this.total * fraction);
    let cumulative = 0;
    for (let index = 0; index < this.counts.length; index += 1) {
      cumulative += this.counts[index];
      if (cumulative >= target) {
        if (index === 0) return Math.min(this.maximum, this.lowestTrackable);
        const upper = this.lowestTrackable * Math.exp((index + 1) * this.logRatio);
        return Math.min(this.maximum, upper);
      }
    }
    throw new Error("histogram count invariant failed");
  }

  serialize() {
    const bins = [];
    for (let index = 0; index < this.counts.length; index += 1) {
      if (this.counts[index] > 0) bins.push([index, this.counts[index]]);
    }
    return {
      lowestTrackable: this.lowestTrackable,
      highestTrackable: this.highestTrackable,
      relativePrecision: this.relativePrecision,
      bucketCount: this.bucketCount,
      total: this.total,
      sum: this.sum,
      minimum: this.total === 0 ? null : this.minimum,
      maximum: this.total === 0 ? null : this.maximum,
      underflow: this.underflow,
      overflow: this.overflow,
      percentiles: {
        p50: this.percentile(0.5),
        p95: this.percentile(0.95),
        p99: this.percentile(0.99),
      },
      bins,
    };
  }
}
