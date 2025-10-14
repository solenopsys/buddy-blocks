import { IStorage, IFileController } from './interfaces.js';
import {
  BlockMetadata,
  BlockSize,
  BlockInfo,
  nextPowerOfTwo,
  makeFreeListKey,
  formatBlockSize,
  MACRO_BLOCK_SIZE,
  MAX_BLOCK_SIZE,
} from './types.js';

/**
 * Block allocation result - tells caller where to write data
 */
export interface AllocateResult {
  offset: bigint;
  blockSize: BlockSize;
}

/**
 * Block Controller implementing buddy allocator algorithm
 * Only manages metadata and allocation, no actual data I/O
 */
export class BlockController {
  private storage: IStorage;
  private fileController: IFileController;

  constructor(storage: IStorage, fileController: IFileController) {
    this.storage = storage;
    this.fileController = fileController;
  }

  /**
   * Allocate block for data with given info
   * Returns offset where data should be written
   */
  allocate(info: BlockInfo): AllocateResult {
    // 1. Check if block already exists
    const existing = this.storage.get(info.hash);
    if (existing && 'blockSize' in existing) {
      throw new Error(`Block with hash ${info.hash} already exists`);
    }

    // 2. Determine required block size
    const blockSize = nextPowerOfTwo(info.dataLength);

    // 3. Allocate block
    const metadata = this.allocateBlock(blockSize);

    // 4. Calculate offset
    const offset = metadata.blockNum * BigInt(blockSize);

    // 5. Save metadata
    this.storage.set(info.hash, metadata);

    return { offset, blockSize };
  }

  /**
   * Get block metadata by hash
   * Returns offset where data is located
   */
  getBlock(hash: string): AllocateResult {
    const metadata = this.storage.get(hash);
    if (!metadata || !('blockSize' in metadata)) {
      throw new Error(`Block with hash ${hash} not found`);
    }

    const blockMetadata = metadata as BlockMetadata;
    const offset = blockMetadata.blockNum * BigInt(blockMetadata.blockSize);

    return { offset, blockSize: blockMetadata.blockSize };
  }

  /**
   * Free block by hash
   */
  free(hash: string): void {
    // 1. Get metadata
    const metadata = this.storage.get(hash);
    if (!metadata || !('blockSize' in metadata)) {
      throw new Error(`Block with hash ${hash} not found`);
    }

    const blockMetadata = metadata as BlockMetadata;

    // 2. Delete metadata
    this.storage.delete(hash);

    // 3. Free block (with buddy merge)
    this.freeBlock(blockMetadata.blockSize, blockMetadata.blockNum, blockMetadata.buddyNum);
  }

  /**
   * Check if block exists
   */
  has(hash: string): boolean {
    const metadata = this.storage.get(hash);
    return metadata !== undefined && 'blockSize' in metadata;
  }

  /**
   * Allocate block of given size
   */
  private allocateBlock(blockSize: BlockSize): BlockMetadata {
    // 1. Try to find free block with cursor range scan
    const prefix = `${formatBlockSize(blockSize)}_`;
    const freeBlock = this.storage.getFirstWithPrefix(prefix);

    if (freeBlock) {
      // Found free block
      const { key, value } = freeBlock;

      // Extract block number from key (e.g., "4k_15" -> 15)
      const blockNum = BigInt(key.split('_')[1]);

      // Remove from free list
      this.storage.delete(key);

      return {
        blockSize,
        blockNum,
        buddyNum: value.buddyNum,
      };
    }

    // 2. No free block found, try to split larger block
    const largerBlock = this.findAndSplitLargerBlock(blockSize);
    if (largerBlock) {
      return largerBlock;
    }

    // 3. No suitable blocks, extend file
    this.createNewMacroBlock();

    // 4. Recursively try to allocate again
    return this.allocateBlock(blockSize);
  }

  /**
   * Find a larger free block and split it down to required size
   */
  private findAndSplitLargerBlock(targetSize: BlockSize): BlockMetadata | null {
    // Try to find any larger free block
    let currentSize = targetSize * 2;

    while (currentSize <= MAX_BLOCK_SIZE) {
      const prefix = `${formatBlockSize(currentSize as BlockSize)}_`;
      const freeBlock = this.storage.getFirstWithPrefix(prefix);

      if (freeBlock) {
        // Found larger block, split it down
        const { key } = freeBlock;
        const blockNum = BigInt(key.split('_')[1]);

        // Remove from free list
        this.storage.delete(key);

        // Split down to target size
        return this.buddySplit(currentSize as BlockSize, blockNum, targetSize);
      }

      currentSize *= 2;
    }

    return null;
  }

  /**
   * Buddy split: split a block down to target size
   */
  private buddySplit(currentSize: BlockSize, blockNum: bigint, targetSize: BlockSize): BlockMetadata {
    // If we reached target size, return it
    if (currentSize === targetSize) {
      // Calculate buddy number based on whether this is left or right buddy
      const buddyNum = blockNum % 2n === 0n ? blockNum + 1n : blockNum - 1n;

      return {
        blockSize: currentSize,
        blockNum,
        buddyNum,
      };
    }

    // Split current block into two smaller blocks
    const halfSize = (currentSize / 2) as BlockSize;

    // Left buddy keeps same block number, right buddy gets next number
    const leftBlockNum = blockNum * 2n;
    const rightBlockNum = leftBlockNum + 1n;

    // Add right buddy to free list
    const rightKey = makeFreeListKey(halfSize, rightBlockNum);
    this.storage.set(rightKey, { buddyNum: leftBlockNum });

    // Continue splitting left buddy
    return this.buddySplit(halfSize, leftBlockNum, targetSize);
  }

  /**
   * Create new macro block (1MB) by extending file
   */
  private createNewMacroBlock(): void {
    const currentSize = this.fileController.getSize();

    // Extend file by 1MB
    this.fileController.extend(BigInt(MACRO_BLOCK_SIZE));

    // Calculate macro block number (at 1MB level)
    const macroBlockNum = currentSize / BigInt(MACRO_BLOCK_SIZE);

    // Add 1MB block to free list
    const block1m = MAX_BLOCK_SIZE;
    const key = makeFreeListKey(block1m, macroBlockNum);

    // For 1MB block, buddy is the next 1MB block
    this.storage.set(key, { buddyNum: macroBlockNum + 1n });
  }

  /**
   * Free block and try to merge with buddy
   */
  private freeBlock(blockSize: BlockSize, blockNum: bigint, buddyNum: bigint): void {
    // Check if we reached max size
    if (blockSize === MAX_BLOCK_SIZE) {
      // Can't merge further, just add to free list
      const key = makeFreeListKey(blockSize, blockNum);
      this.storage.set(key, { buddyNum });
      return;
    }

    // Check if buddy is free
    const buddyKey = makeFreeListKey(blockSize, buddyNum);
    const buddyFree = this.storage.get(buddyKey);

    if (buddyFree && 'buddyNum' in buddyFree) {
      // Buddy is free, merge!

      // Remove buddy from free list
      this.storage.delete(buddyKey);

      // Calculate parent block
      const parentSize = (blockSize * 2) as BlockSize;
      // Parent block number is min(blockNum, buddyNum) / 2
      const minBlockNum = blockNum < buddyNum ? blockNum : buddyNum;
      const parentNum = minBlockNum / 2n;

      // Calculate parent's buddy
      const parentBuddyNum = parentNum % 2n === 0n ? parentNum + 1n : parentNum - 1n;

      // Recursively free parent block (may merge further)
      this.freeBlock(parentSize, parentNum, parentBuddyNum);
    } else {
      // Buddy is not free, just add to free list
      const key = makeFreeListKey(blockSize, blockNum);
      this.storage.set(key, { buddyNum });
    }
  }

  /**
   * Get storage statistics (for debugging/testing)
   */
  getStats(): {
    fileSize: bigint;
    freeBlocks: Record<string, number>;
    usedBlocks: number;
  } {
    const stats = {
      fileSize: this.fileController.getSize(),
      freeBlocks: {} as Record<string, number>,
      usedBlocks: 0,
    };

    // Count free blocks by size
    const allKeys = this.storage.getAllWithPrefix('');
    for (const { key } of allKeys) {
      // Free list keys: "4k_123", "512k_5", "1m_2"
      // Block metadata keys: any hash (no underscore + size pattern)
      if (key.match(/^\d+[km]_\d+$/)) {
        const [sizeStr] = key.split('_');
        stats.freeBlocks[sizeStr] = (stats.freeBlocks[sizeStr] || 0) + 1;
      } else {
        // Hash entry (used block)
        stats.usedBlocks++;
      }
    }

    return stats;
  }
}
