import { BlockController } from './block-controller.js';
import { LMDBStorage } from './lmdb-storage.js';
import { MockFileController } from './mock-file-controller.js';
import { existsSync, rmSync } from 'fs';

console.log('LMDB Benchmark with Transactions');
console.log('='.repeat(60));

if (existsSync('./data')) {
  rmSync('./data', { recursive: true, force: true });
}

const storage = new LMDBStorage();
const fileController = new MockFileController();
const controller = new BlockController(storage, fileController);

// Test with transaction wrapper
console.log('\n1. Allocating 1000 blocks in one transaction...');
const start = performance.now();

storage.transaction(() => {
  for (let i = 0; i < 1000; i++) {
    controller.allocate({ hash: `block_${i}`, dataLength: 4096 });
  }
});

const end = performance.now();

console.log(`Time: ${(end - start).toFixed(2)}ms`);
console.log(`Ops/sec: ${Math.round(1000 / ((end - start) / 1000)).toLocaleString()}`);
console.log(`File size: ${(Number(fileController.getSize()) / 1024 / 1024).toFixed(2)} MB`);

storage.close();
