import { BlockController } from './block-controller.js';
import { MockStorage } from './mock-storage.js';
import { MockFileController } from './mock-file-controller.js';

const storage = new MockStorage();
const fileController = new MockFileController();
const controller = new BlockController(storage, fileController);

console.log('Profiling allocations...\n');

// Test 1: Sequential allocations
const count = 10000;
let start = performance.now();

for (let i = 0; i < count; i++) {
  controller.allocate({ hash: `block_${i}`, dataLength: 4096 });
}

let end = performance.now();
console.log(`${count} allocations: ${(end - start).toFixed(2)}ms`);
console.log(`Avg per op: ${((end - start) / count).toFixed(3)}ms`);
console.log(`Ops/sec: ${Math.round(count / ((end - start) / 1000)).toLocaleString()}`);

console.log('\nProfiling gets...\n');

// Test 2: Random gets
start = performance.now();

for (let i = 0; i < count; i++) {
  const hash = `block_${Math.floor(Math.random() * count)}`;
  try {
    controller.getBlock(hash);
  } catch (e) {}
}

end = performance.now();
console.log(`${count} gets: ${(end - start).toFixed(2)}ms`);
console.log(`Avg per op: ${((end - start) / count).toFixed(3)}ms`);
console.log(`Ops/sec: ${Math.round(count / ((end - start) / 1000)).toLocaleString()}`);

console.log('\nProfiling frees...\n');

// Test 3: Sequential frees
start = performance.now();

for (let i = 0; i < count; i++) {
  controller.free(`block_${i}`);
}

end = performance.now();
console.log(`${count} frees: ${(end - start).toFixed(2)}ms`);
console.log(`Avg per op: ${((end - start) / count).toFixed(3)}ms`);
console.log(`Ops/sec: ${Math.round(count / ((end - start) / 1000)).toLocaleString()}`);

const stats = controller.getStats();
console.log(`\nFinal state:`);
console.log(`File size: ${(Number(stats.fileSize) / 1024 / 1024).toFixed(2)} MB`);
console.log(`Used blocks: ${stats.usedBlocks}`);
