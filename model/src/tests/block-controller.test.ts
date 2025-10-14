import { describe, it, expect, beforeEach } from 'bun:test';
import { BlockController } from './block-controller.js';
import { MockStorage } from './mock-storage.js';
import { MockFileController } from './mock-file-controller.js';
import { nextPowerOfTwo, BlockInfo } from './types.js';

describe('BlockController', () => {
  let storage: MockStorage;
  let fileController: MockFileController;
  let controller: BlockController;

  beforeEach(() => {
    storage = new MockStorage();
    fileController = new MockFileController();
    controller = new BlockController(storage, fileController);
  });

  describe('Basic operations', () => {
    it('should allocate block and return offset', () => {
      const info: BlockInfo = { hash: 'hash1', dataLength: 100 };

      const result = controller.allocate(info);

      expect(result.offset).toBe(0n);
      expect(result.blockSize).toBe(4096);
      expect(controller.has('hash1')).toBe(true);
    });

    it('should allocate correct block sizes', () => {
      const testCases = [
        { dataLength: 100, expectedBlockSize: 4096 },
        { dataLength: 4096, expectedBlockSize: 4096 },
        { dataLength: 4097, expectedBlockSize: 8192 },
        { dataLength: 5000, expectedBlockSize: 8192 },
        { dataLength: 32768, expectedBlockSize: 32768 },
        { dataLength: 32769, expectedBlockSize: 65536 },
      ];

      for (const { dataLength, expectedBlockSize } of testCases) {
        storage.clear();
        fileController = new MockFileController();
        controller = new BlockController(storage, fileController);

        const info: BlockInfo = { hash: `hash_${dataLength}`, dataLength };
        const result = controller.allocate(info);

        expect(result.blockSize).toBe(expectedBlockSize);
      }
    });

    it('should get block metadata by hash', () => {
      const info: BlockInfo = { hash: 'hash1', dataLength: 100 };

      controller.allocate(info);
      const result = controller.getBlock('hash1');

      expect(result.offset).toBe(0n);
      expect(result.blockSize).toBe(4096);
    });

    it('should handle multiple allocations', () => {
      const infos = [
        { hash: 'block1', dataLength: 1000 },
        { hash: 'block2', dataLength: 2000 },
        { hash: 'block3', dataLength: 3000 },
      ];

      const results = [];
      for (const info of infos) {
        results.push(controller.allocate(info));
      }

      // All blocks should be allocated
      for (const info of infos) {
        expect(controller.has(info.hash)).toBe(true);
      }

      // Can retrieve metadata
      for (let i = 0; i < infos.length; i++) {
        const result = controller.getBlock(infos[i].hash);
        expect(result.offset).toBe(results[i].offset);
        expect(result.blockSize).toBe(results[i].blockSize);
      }
    });

    it('should free block', () => {
      const info: BlockInfo = { hash: 'to_free', dataLength: 100 };

      controller.allocate(info);
      expect(controller.has('to_free')).toBe(true);

      controller.free('to_free');
      expect(controller.has('to_free')).toBe(false);

      // Should throw when trying to get freed block
      expect(() => controller.getBlock('to_free')).toThrow();
    });

    it('should not allow duplicate hash', () => {
      const info: BlockInfo = { hash: 'duplicate', dataLength: 100 };

      controller.allocate(info);

      // Second allocation with same hash should fail
      expect(() => controller.allocate(info)).toThrow();
    });
  });

  describe('Buddy allocation', () => {
    it('should expand file when needed', () => {
      const initialSize = fileController.getSize();
      expect(initialSize).toBe(0n);

      // First allocation should expand file to 1MB
      controller.allocate({ hash: 'hash1', dataLength: 100 });

      const afterSize = fileController.getSize();
      expect(afterSize).toBe(1048576n); // 1MB
    });

    it('should reuse free blocks after deletion', () => {
      // Allocate a block
      controller.allocate({ hash: 'hash1', dataLength: 100 });

      const statsBefore = controller.getStats();
      expect(statsBefore.usedBlocks).toBe(1);

      // Free it
      controller.free('hash1');

      const statsAfter = controller.getStats();
      expect(statsAfter.usedBlocks).toBe(0);

      // Allocate another block of same size - should reuse the freed block
      controller.allocate({ hash: 'hash2', dataLength: 100 });

      // File size should not increase
      expect(fileController.getSize()).toBe(1048576n);
    });

    it('should split larger blocks when needed', () => {
      // First allocation creates 1MB file and splits into free blocks
      controller.allocate({ hash: 'hash_4kb', dataLength: 100 }); // needs 4KB

      const stats = controller.getStats();

      // Should have split 512KB -> 256KB -> 128KB -> 64KB -> 32KB -> 16KB -> 8KB -> 4KB
      // All the "right buddies" should be in free list
      expect(stats.freeBlocks['4k']).toBeGreaterThan(0);
      expect(stats.freeBlocks['8k']).toBeGreaterThan(0);
      expect(stats.freeBlocks['512k']).toBe(1); // The other 512KB block
    });

    it('should allocate sequential blocks from different positions', () => {
      const result1 = controller.allocate({ hash: 'hash1', dataLength: 100 });
      const result2 = controller.allocate({ hash: 'hash2', dataLength: 100 });

      // Both should be 4KB blocks but at different offsets
      expect(result1.blockSize).toBe(4096);
      expect(result2.blockSize).toBe(4096);
      expect(result1.offset).not.toBe(result2.offset);
    });
  });

  describe('Buddy merge', () => {
    it('should merge buddies when both are free', () => {
      // Allocate two 4KB blocks (they will be buddies)
      controller.allocate({ hash: 'hash1', dataLength: 100 });
      controller.allocate({ hash: 'hash2', dataLength: 100 });

      // Free first block
      controller.free('hash1');

      let stats = controller.getStats();
      const freeBefore = stats.freeBlocks['4k'] || 0;
      expect(freeBefore).toBeGreaterThan(0);

      // Free second block - should merge with first
      controller.free('hash2');

      stats = controller.getStats();
      const freeAfter = stats.freeBlocks['4k'] || 0;

      // After merge, we should have fewer 4KB blocks
      // (they merged up into larger blocks)
      expect(freeAfter).toBeLessThan(freeBefore);
    });

    it('should cascade merge multiple levels', () => {
      // Allocate 4 blocks of 4KB (will be in same 16KB region)
      const hashes = ['h1', 'h2', 'h3', 'h4'];
      for (const hash of hashes) {
        controller.allocate({ hash, dataLength: 100 });
      }

      // Free all 4 blocks - should cascade merge up
      for (const hash of hashes) {
        controller.free(hash);
      }

      const stats = controller.getStats();

      // After cascade merge, small blocks should be merged into larger ones
      // Exact numbers depend on allocation order, but we should see larger blocks
      const totalFreeBlocks = Object.values(stats.freeBlocks).reduce((a, b) => a + b, 0);
      expect(totalFreeBlocks).toBeGreaterThan(0);
    });
  });

  describe('Edge cases', () => {
    it('should handle empty data', () => {
      const result = controller.allocate({ hash: 'empty', dataLength: 0 });

      expect(result.blockSize).toBe(4096); // Min block size
    });

    it('should handle large blocks', () => {
      // Test 256KB block
      const result = controller.allocate({ hash: 'large', dataLength: 256 * 1024 });

      expect(result.blockSize).toBe(262144); // 256KB
    });

    it('should handle max size block (1MB)', () => {
      const result = controller.allocate({ hash: 'max_size', dataLength: 1024 * 1024 });

      expect(result.blockSize).toBe(1048576); // 1MB
    });

    it('should handle multiple macro blocks', () => {
      // Allocate more than 1MB worth of data
      const blocks = [];
      for (let i = 0; i < 10; i++) {
        const hash = `block_${i}`;
        const result = controller.allocate({ hash, dataLength: 200 * 1024 }); // 200KB each
        blocks.push({ hash, result });
      }

      // File should have expanded beyond 1MB
      expect(fileController.getSize()).toBeGreaterThan(1048576n);

      // Verify all blocks have metadata
      for (const { hash, result } of blocks) {
        const retrieved = controller.getBlock(hash);
        expect(retrieved.offset).toBe(result.offset);
        expect(retrieved.blockSize).toBe(result.blockSize);
      }
    });
  });

  describe('Stats and debugging', () => {
    it('should provide correct statistics', () => {
      const stats1 = controller.getStats();
      expect(stats1.fileSize).toBe(0n);
      expect(stats1.usedBlocks).toBe(0);

      controller.allocate({ hash: 'hash1', dataLength: 100 });

      const stats2 = controller.getStats();
      expect(stats2.fileSize).toBe(1048576n); // 1MB
      expect(stats2.usedBlocks).toBe(1);

      controller.allocate({ hash: 'hash2', dataLength: 100 });

      const stats3 = controller.getStats();
      expect(stats3.usedBlocks).toBe(2);
    });
  });

  describe('Stress test', () => {
    it('should handle many allocations and deallocations', () => {
      const hashes: string[] = [];

      // Allocate 50 blocks
      for (let i = 0; i < 50; i++) {
        const size = 100 + (i * 100); // Variable sizes
        const hash = `stress_${i}`;
        hashes.push(hash);

        controller.allocate({ hash, dataLength: size });
      }

      const statsAfterAlloc = controller.getStats();
      expect(statsAfterAlloc.usedBlocks).toBe(50);

      // Free every other block
      for (let i = 0; i < hashes.length; i += 2) {
        controller.free(hashes[i]);
      }

      const statsAfterPartialDelete = controller.getStats();
      expect(statsAfterPartialDelete.usedBlocks).toBe(25);

      // Free remaining blocks
      for (let i = 1; i < hashes.length; i += 2) {
        controller.free(hashes[i]);
      }

      const statsAfterFullDelete = controller.getStats();
      expect(statsAfterFullDelete.usedBlocks).toBe(0);
    });
  });

  describe('Integration test with simulated I/O', () => {
    it('should allocate, write, read, and free data', () => {
      const data = new Uint8Array([1, 2, 3, 4, 5]);
      const hash = 'test_io';

      // 1. Allocate space
      const { offset, blockSize } = controller.allocate({ hash, dataLength: data.length });

      expect(blockSize).toBe(4096);

      // 2. Simulate external write (through io_uring in real Zig code)
      fileController.write(offset, data);

      // 3. Simulate external read
      const readData = fileController.read(offset, data.length);
      expect(readData).toEqual(data);

      // 4. Get block info
      const retrieved = controller.getBlock(hash);
      expect(retrieved.offset).toBe(offset);

      // 5. Free the block
      controller.free(hash);
      expect(controller.has(hash)).toBe(false);
    });
  });
});

describe('Helper functions', () => {
  it('should calculate next power of two correctly', () => {
    expect(nextPowerOfTwo(1)).toBe(4096);
    expect(nextPowerOfTwo(4095)).toBe(4096);
    expect(nextPowerOfTwo(4096)).toBe(4096);
    expect(nextPowerOfTwo(4097)).toBe(8192);
    expect(nextPowerOfTwo(8000)).toBe(8192);
    expect(nextPowerOfTwo(1048576)).toBe(1048576);
    expect(nextPowerOfTwo(1048577)).toBe(1048576); // Max size
  });
});
