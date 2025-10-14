import { BlockController } from './block-controller.js';
import { MockStorage } from './mock-storage.js';
import { MockFileController } from './mock-file-controller.js';

// Patch storage to count operations
class ProfiledStorage extends MockStorage {
  getCount = 0;
  setCount = 0;
  deleteCount = 0;
  getPrefixCount = 0;

  get(key: string) {
    this.getCount++;
    return super.get(key);
  }

  set(key: string, value: any) {
    this.setCount++;
    return super.set(key, value);
  }

  delete(key: string) {
    this.deleteCount++;
    return super.delete(key);
  }

  getFirstWithPrefix(prefix: string) {
    this.getPrefixCount++;
    return super.getFirstWithPrefix(prefix);
  }

  reset() {
    this.getCount = 0;
    this.setCount = 0;
    this.deleteCount = 0;
    this.getPrefixCount = 0;
  }
}

const storage = new ProfiledStorage();
const fileController = new MockFileController();
const controller = new BlockController(storage, fileController);

console.log('Profiling 1000 allocations of 4KB blocks...\n');

const start = performance.now();

for (let i = 0; i < 1000; i++) {
  controller.allocate({ hash: `block_${i}`, dataLength: 4096 });
}

const end = performance.now();

console.log(`Time: ${(end - start).toFixed(2)}ms`);
console.log(`Ops/sec: ${Math.round(1000 / ((end - start) / 1000)).toLocaleString()}`);
console.log();
console.log('Storage operations:');
console.log(`  get():               ${storage.getCount.toLocaleString()}`);
console.log(`  set():               ${storage.setCount.toLocaleString()}`);
console.log(`  delete():            ${storage.deleteCount.toLocaleString()}`);
console.log(`  getFirstWithPrefix():${storage.getPrefixCount.toLocaleString()}`);
console.log();
console.log(`Avg ops per allocation:`);
console.log(`  get():               ${(storage.getCount / 1000).toFixed(1)}`);
console.log(`  set():               ${(storage.setCount / 1000).toFixed(1)}`);
console.log(`  delete():            ${(storage.deleteCount / 1000).toFixed(1)}`);
console.log(`  getFirstWithPrefix():${(storage.getPrefixCount / 1000).toFixed(1)}`);
console.log();

// Test with variable sizes
storage.reset();

console.log('Profiling 1000 allocations with random sizes (100B - 100KB)...\n');

const start2 = performance.now();

for (let i = 0; i < 1000; i++) {
  const size = Math.floor(Math.random() * 100 * 1024) + 100;
  controller.allocate({ hash: `block_rand_${i}`, dataLength: size });
}

const end2 = performance.now();

console.log(`Time: ${(end2 - start2).toFixed(2)}ms`);
console.log(`Ops/sec: ${Math.round(1000 / ((end2 - start2) / 1000)).toLocaleString()}`);
console.log();
console.log('Storage operations:');
console.log(`  get():               ${storage.getCount.toLocaleString()}`);
console.log(`  set():               ${storage.setCount.toLocaleString()}`);
console.log(`  delete():            ${storage.deleteCount.toLocaleString()}`);
console.log(`  getFirstWithPrefix():${storage.getPrefixCount.toLocaleString()}`);
console.log();
console.log(`Avg ops per allocation:`);
console.log(`  get():               ${(storage.getCount / 1000).toFixed(1)}`);
console.log(`  set():               ${(storage.setCount / 1000).toFixed(1)}`);
console.log(`  delete():            ${(storage.deleteCount / 1000).toFixed(1)}`);
console.log(`  getFirstWithPrefix():${(storage.getPrefixCount / 1000).toFixed(1)}`);
