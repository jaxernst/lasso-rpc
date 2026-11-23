// Deterministic, validly signed EIP-1559 transactions with node:crypto and BigInt only:
// keccak-256, RLP, and secp256k1 ECDSA with RFC 6979 nonces and low-s signatures.
import crypto from "node:crypto";

const MASK = (1n << 64n) - 1n;
const RC = [
  0x0000000000000001n, 0x0000000000008082n, 0x800000000000808an, 0x8000000080008000n, 0x000000000000808bn, 0x0000000080000001n,
  0x8000000080008081n, 0x8000000000008009n, 0x000000000000008an, 0x0000000000000088n, 0x0000000080008009n, 0x000000008000000an,
  0x000000008000808bn, 0x800000000000008bn, 0x8000000000008089n, 0x8000000000008003n, 0x8000000000008002n, 0x8000000000000080n,
  0x000000000000800an, 0x800000008000000an, 0x8000000080008081n, 0x8000000000008080n, 0x0000000080000001n, 0x8000000080008008n,
];
const ROT = [0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39, 41, 45, 15, 21, 8, 18, 2, 61, 56, 14].map(BigInt);
const rotl = (x, n) => (n === 0n ? x : ((x << n) | (x >> (64n - n))) & MASK);

function keccakF(s) {
  const b = new Array(25);
  for (const rc of RC) {
    const c = [0, 1, 2, 3, 4].map((x) => s[x] ^ s[x + 5] ^ s[x + 10] ^ s[x + 15] ^ s[x + 20]);
    for (let x = 0; x < 5; x++) {
      const d = c[(x + 4) % 5] ^ rotl(c[(x + 1) % 5], 1n);
      for (let y = 0; y < 25; y += 5) s[x + y] ^= d;
    }
    for (let x = 0; x < 5; x++) for (let y = 0; y < 5; y++) b[y + 5 * ((2 * x + 3 * y) % 5)] = rotl(s[x + 5 * y], ROT[x + 5 * y]);
    for (let y = 0; y < 25; y += 5) for (let x = 0; x < 5; x++) s[x + y] = b[x + y] ^ (~b[((x + 1) % 5) + y] & MASK & b[((x + 2) % 5) + y]);
    s[0] ^= rc;
  }
}

export function keccak256(data) {
  const rate = 136;
  const padded = Buffer.alloc(Math.floor(data.length / rate) * rate + rate);
  Buffer.from(data).copy(padded);
  padded[data.length] ^= 0x01;
  padded[padded.length - 1] ^= 0x80;
  const s = new Array(25).fill(0n);
  for (let off = 0; off < padded.length; off += rate) {
    for (let i = 0; i < rate / 8; i++) s[i] ^= padded.readBigUInt64LE(off + i * 8);
    keccakF(s);
  }
  const out = Buffer.alloc(32);
  for (let i = 0; i < 4; i++) out.writeBigUInt64LE(s[i], i * 8);
  return out;
}

const intBytes = (n) => (n === 0n ? Buffer.alloc(0) : Buffer.from(n.toString(16).padStart(Math.ceil(n.toString(16).length / 2) * 2, "0"), "hex"));
const lengthPrefix = (len, short) => (len <= 55 ? Buffer.from([short + len]) : Buffer.concat([Buffer.from([short + 55 + intBytes(BigInt(len)).length]), intBytes(BigInt(len))]));
export function rlp(item) {
  if (Array.isArray(item)) {
    const body = Buffer.concat(item.map(rlp));
    return Buffer.concat([lengthPrefix(body.length, 0xc0), body]);
  }
  const b = typeof item === "bigint" ? intBytes(item) : Buffer.from(item);
  return b.length === 1 && b[0] < 0x80 ? b : Buffer.concat([lengthPrefix(b.length, 0x80), b]);
}

const P = 2n ** 256n - 2n ** 32n - 977n;
const N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;
const G = [0x79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798n, 0x483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8n];
const mod = (a, m) => ((a % m) + m) % m;
function inv(a, m) {
  let [r0, r1, t0, t1] = [mod(a, m), m, 1n, 0n];
  while (r1) { const q = r0 / r1; [r0, r1] = [r1, r0 - q * r1]; [t0, t1] = [t1, t0 - q * t1]; }
  return mod(t0, m);
}
function add(a, b) {
  if (!a) return b;
  if (!b) return a;
  if (a[0] === b[0] && mod(a[1] + b[1], P) === 0n) return null;
  const l = a[0] === b[0] ? mod(3n * a[0] * a[0] * inv(2n * a[1], P), P) : mod((b[1] - a[1]) * inv(b[0] - a[0], P), P);
  const x = mod(l * l - a[0] - b[0], P);
  return [x, mod(l * (a[0] - x) - a[1], P)];
}
function mul(k, pt = G) {
  let r = null;
  for (let q = pt; k > 0n; k >>= 1n, q = add(q, q)) if (k & 1n) r = add(r, q);
  return r;
}
const be32 = (n) => Buffer.from(n.toString(16).padStart(64, "0"), "hex");
const toInt = (b) => BigInt("0x" + Buffer.from(b).toString("hex"));
const hmac = (k, ...parts) => crypto.createHmac("sha256", k).update(Buffer.concat(parts)).digest();

function rfc6979(d, h) {
  const x = be32(d), h1 = be32(mod(toInt(h), N));
  let v = Buffer.alloc(32, 1), k = Buffer.alloc(32, 0);
  k = hmac(k, v, Buffer.from([0]), x, h1); v = hmac(k, v);
  k = hmac(k, v, Buffer.from([1]), x, h1); v = hmac(k, v);
  for (;;) {
    v = hmac(k, v);
    const cand = toInt(v);
    if (cand > 0n && cand < N) return cand;
    k = hmac(k, v, Buffer.from([0])); v = hmac(k, v);
  }
}

export function sign(hash, d) {
  const z = toInt(hash);
  const k = rfc6979(d, hash);
  const R = mul(k);
  const r = mod(R[0], N);
  let s = mod(inv(k, N) * (z + r * d), N);
  let yParity = Number(R[1] & 1n);
  if (s > N / 2n) { s = N - s; yParity ^= 1; }
  return { r, s, yParity };
}

export function address(d) {
  const [x, y] = mul(d);
  return "0x" + keccak256(Buffer.concat([be32(x), be32(y)])).subarray(12).toString("hex");
}

export const TEST_KEY = toInt(keccak256(Buffer.from("lasso routing trial kit test key")));

// A 21,000-gas transfer of 0 to a fixed address, signed with TEST_KEY.
export function signedTransfer({ chainId, nonce, key = TEST_KEY }) {
  const to = Buffer.from("00000000000000000000000000000000c0ffee02", "hex");
  const fields = [BigInt(chainId), BigInt(nonce), 1_000_000_000n, 60_000_000_000n, 21_000n, to, 0n, Buffer.alloc(0), []];
  const { r, s, yParity } = sign(keccak256(Buffer.concat([Buffer.from([2]), rlp(fields)])), key);
  const raw = Buffer.concat([Buffer.from([2]), rlp([...fields, BigInt(yParity), r, s])]);
  return { raw: "0x" + raw.toString("hex"), hash: "0x" + keccak256(raw).toString("hex") };
}

export const txHash = (rawHex) => "0x" + keccak256(Buffer.from(String(rawHex).replace(/^0x/, ""), "hex")).toString("hex");
