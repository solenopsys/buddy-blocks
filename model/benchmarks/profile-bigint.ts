// Test BigInt performance

console.log('Testing BigInt operations...\n');

// Test 1: BigInt creation
let start = performance.now();
for (let i = 0; i < 1_000_000; i++) {
  BigInt(i);
}
let end = performance.now();
console.log(`1M BigInt() conversions: ${(end - start).toFixed(2)}ms`);
console.log(`Ops/sec: ${Math.round(1_000_000 / ((end - start) / 1000)).toLocaleString()}`);
console.log();

// Test 2: BigInt arithmetic
start = performance.now();
let sum = 0n;
for (let i = 0; i < 1_000_000; i++) {
  sum = BigInt(i) * 2n;
}
end = performance.now();
console.log(`1M BigInt multiply: ${(end - start).toFixed(2)}ms`);
console.log(`Ops/sec: ${Math.round(1_000_000 / ((end - start) / 1000)).toLocaleString()}`);
console.log();

// Test 3: String split (как в extractPrefix)
start = performance.now();
for (let i = 0; i < 1_000_000; i++) {
  const key = `4k_${i}`;
  const num = BigInt(key.split('_')[1]);
}
end = performance.now();
console.log(`1M string split + BigInt: ${(end - start).toFixed(2)}ms`);
console.log(`Ops/sec: ${Math.round(1_000_000 / ((end - start) / 1000)).toLocaleString()}`);
console.log();

// Test 4: Array sort (как в prefixIndex)
const keys = Array.from({ length: 10000 }, (_, i) => `4k_${i}`);
start = performance.now();
for (let i = 0; i < 100; i++) {
  [...keys].sort();
}
end = performance.now();
console.log(`100 sorts of 10K strings: ${(end - start).toFixed(2)}ms`);
console.log(`Per sort: ${((end - start) / 100).toFixed(2)}ms`);
