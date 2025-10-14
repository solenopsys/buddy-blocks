import { BlockController } from './block-controller.js';
import { LMDBStorage } from './lmdb-storage.js';
import { MockFileController } from './mock-file-controller.js';
import { existsSync, rmSync } from 'fs';

console.log('LMDB Benchmark');
console.log('='.repeat(60));

// Clean up old db before test
console.log('Cleaning up old database...');
if (existsSync('./data')) {
  rmSync('./data', { recursive: true, force: true });
}

const storage = new LMDBStorage();
const fileController = new MockFileController();
const controller = new BlockController(storage, fileController);

// Test 1: Sequential 4KB allocations
console.log('\n1. Sequential 4KB allocations (100 iterations)...');
let start = performance.now();

for (let i = 0; i < 100; i++) {
  controller.allocate({ hash: `block_${i}`, dataLength: 4096 });
}

let end = performance.now();
console.log(`Time: ${(end - start).toFixed(2)}ms`);
console.log(`Ops/sec: ${Math.round(100 / ((end - start) / 1000)).toLocaleString()}`);

// Test 2: Gets
console.log('\n2. Random gets (100 iterations)...');
start = performance.now();

for (let i = 0; i < 100; i++) {
  const hash = `block_${Math.floor(Math.random() * 100)}`;
  try {
    controller.getBlock(hash);
  } catch (e) {}
}

end = performance.now();
console.log(`Time: ${(end - start).toFixed(2)}ms`);
console.log(`Ops/sec: ${Math.round(100 / ((end - start) / 1000)).toLocaleString()}`);

// Test 3: Random sizes
console.log('\n3. Random size allocations (10 iterations)...');
start = performance.now();

for (let i = 0; i < 10; i++) {
  const size = Math.floor(Math.random() * 100 * 1024) + 100;
  controller.allocate({ hash: `rand_${i}`, dataLength: size });
}

end = performance.now();
console.log(`Time: ${(end - start).toFixed(2)}ms`);
console.log(`Ops/sec: ${Math.round(10 / ((end - start) / 1000)).toLocaleString()}`);

console.log('\n' + '='.repeat(60));
console.log('Done! File size:', (Number(fileController.getSize()) / 1024 / 1024).toFixed(2), 'MB');

storage.close();
