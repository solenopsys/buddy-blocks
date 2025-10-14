import { BlockController } from './block-controller.js';
import { MockStorage } from './mock-storage.js';
import { MockFileController } from './mock-file-controller.js';

const storage = new MockStorage();
const fileController = new MockFileController();
const controller = new BlockController(storage, fileController);

console.log('Allocating block 1...');
controller.allocate({ hash: 'hash1', dataLength: 100 });

console.log('Allocating block 2...');
controller.allocate({ hash: 'hash2', dataLength: 100 });

console.log('Stats after allocation:');
console.log(controller.getStats());

console.log('\nFreeing hash1...');
controller.free('hash1');

console.log('Stats after freeing hash1:');
console.log(controller.getStats());

console.log('\nFreeing hash2...');
controller.free('hash2');

console.log('Stats after freeing hash2:');
console.log(controller.getStats());

console.log('\nDone!');
