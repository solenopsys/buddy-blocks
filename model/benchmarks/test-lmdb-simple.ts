import { open } from 'lmdb';
import { existsSync, rmSync } from 'fs';

if (existsSync('./data')) {
  rmSync('./data', { recursive: true, force: true });
}

const db = open({
  path: './data/test.lmdb',
});

console.log('Testing LMDB raw performance...\n');

// Test 1: Write 100 keys one by one
console.log('1. Writing 100 keys with putSync...');
let start = performance.now();

for (let i = 0; i < 100; i++) {
  db.putSync(`key_${i}`, { value: i });
}

let end = performance.now();
console.log(`Time: ${(end - start).toFixed(2)}ms`);
console.log(`Ops/sec: ${Math.round(100 / ((end - start) / 1000)).toLocaleString()}`);

// Test 2: Read 100 keys
console.log('\n2. Reading 100 keys...');
start = performance.now();

for (let i = 0; i < 100; i++) {
  db.get(`key_${i}`);
}

end = performance.now();
console.log(`Time: ${(end - start).toFixed(2)}ms`);
console.log(`Ops/sec: ${Math.round(100 / ((end - start) / 1000)).toLocaleString()}`);

// Test 3: Write in transaction
console.log('\n3. Writing 100 keys in one transaction...');
start = performance.now();

db.transactionSync(() => {
  for (let i = 100; i < 200; i++) {
    db.put(`key_${i}`, { value: i });
  }
});

end = performance.now();
console.log(`Time: ${(end - start).toFixed(2)}ms`);
console.log(`Ops/sec: ${Math.round(100 / ((end - start) / 1000)).toLocaleString()}`);

// Test 4: Range query
console.log('\n4. Range query with prefix...');
start = performance.now();

let count = 0;
for (const { key } of db.getRange({ start: 'key_1', end: 'key_2' })) {
  count++;
  break; // Only need first
}

end = performance.now();
console.log(`Time: ${(end - start).toFixed(2)}ms`);
console.log(`Found: ${count} keys`);

db.close();
console.log('\nDone!');
