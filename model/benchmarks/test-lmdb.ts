import { LMDBStorage } from './lmdb-storage.js';
import { existsSync, rmSync } from 'fs';

console.log('Testing LMDB...\n');

// Clean up
if (existsSync('./data')) {
  rmSync('./data', { recursive: true, force: true });
}

const storage = new LMDBStorage();

console.log('1. Writing key...');
storage.set('test_key', { buddyNum: 123n });

console.log('2. Reading key...');
const value = storage.get('test_key');
console.log('Value:', value);

console.log('\n3. Writing free list entry...');
storage.set('4k_0', { buddyNum: 1n });

console.log('4. Getting first with prefix...');
const result = storage.getFirstWithPrefix('4k_');
console.log('Result:', result);

console.log('\n5. Writing block metadata...');
storage.set('hash_abc', { blockSize: 4096, blockNum: 5n, buddyNum: 6n });

console.log('6. Reading block metadata...');
const meta = storage.get('hash_abc');
console.log('Metadata:', meta);

console.log('\nDone!');
storage.close();
