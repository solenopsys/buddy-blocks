import { BlockController } from './block-controller.js';
import { MockStorage } from './mock-storage.js';
import { MockFileController } from './mock-file-controller.js';

const storage = new MockStorage();
const fileController = new MockFileController();
const controller = new BlockController(storage, fileController);

console.log('Testing why random sizes are slow...\n');

// Warm up
for (let i = 0; i < 100; i++) {
  controller.allocate({ hash: `warmup_${i}`, dataLength: 4096 });
}

console.log('After warmup - file size:', fileController.getSize());

// Now test random sizes
const sizes = [];
for (let i = 0; i < 1000; i++) {
  sizes.push(Math.floor(Math.random() * 100 * 1024) + 100);
}

console.log('Starting 1000 random size allocations...');
const start = performance.now();

for (let i = 0; i < sizes.length; i++) {
  const allocStart = performance.now();
  controller.allocate({ hash: `rand_${i}`, dataLength: sizes[i] });
  const allocTime = performance.now() - allocStart;

  if (allocTime > 1.0) {
    console.log(`Slow allocation #${i}: ${allocTime.toFixed(2)}ms, size=${sizes[i]}, fileSize=${fileController.getSize()}`);
  }
}

const end = performance.now();

console.log(`\nTotal time: ${(end - start).toFixed(2)}ms`);
console.log(`Ops/sec: ${Math.round(1000 / ((end - start) / 1000)).toLocaleString()}`);
console.log(`Final file size: ${(Number(fileController.getSize()) / 1024 / 1024).toFixed(2)} MB`);
