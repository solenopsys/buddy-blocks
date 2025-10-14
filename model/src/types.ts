/**
 * Block sizes - powers of 2 from 4KB to 1MB
 */
export type BlockSize = 4096 | 8192 | 16384 | 32768 | 65536 | 131072 | 262144 | 524288 | 1048576;

export const BLOCK_SIZES: readonly BlockSize[] = [
  4096,      // 4KB
  8192,      // 8KB
  16384,     // 16KB
  32768,     // 32KB
  65536,     // 64KB
  131072,    // 128KB
  262144,    // 256KB
  524288,    // 512KB
  1048576,   // 1MB
] as const;

export const MIN_BLOCK_SIZE: BlockSize = 4096;      // 4KB
export const MAX_BLOCK_SIZE: BlockSize = 1048576;   // 1MB
export const MACRO_BLOCK_SIZE = 1048576;            // 1MB

/**
 * Block metadata stored in LMDB
 */
export interface BlockMetadata {
  blockSize: BlockSize;   // Size of the block in bytes
  blockNum: bigint;       // Block number (offset / blockSize)
  buddyNum: bigint;       // Buddy block number for buddy algorithm
}

/**
 * Free list entry value (stored in LMDB)
 */
export interface FreeListEntry {
  buddyNum: bigint;
}

/**
 * Block info - what controller receives to allocate space
 */
export interface BlockInfo {
  hash: string;      // SHA256 hash of data
  dataLength: number; // Actual data length in bytes
}

/**
 * Helper to format block size as string (e.g., "4k", "512k", "1m")
 */
export function formatBlockSize(size: BlockSize): string {
  if (size >= 1048576) return `${size / 1048576}m`;
  return `${size / 1024}k`;
}

/**
 * Helper to create free list key
 */
export function makeFreeListKey(size: BlockSize, blockNum: bigint): string {
  return `${formatBlockSize(size)}_${blockNum}`;
}

/**
 * Helper to parse free list key
 */
export function parseFreeListKey(key: string): { size: BlockSize; blockNum: bigint } | null {
  const match = key.match(/^(\d+)([km])_(\d+)$/);
  if (!match) return null;

  const [, num, unit, blockNumStr] = match;
  const multiplier = unit === 'k' ? 1024 : 1048576;
  const size = parseInt(num) * multiplier as BlockSize;
  const blockNum = BigInt(blockNumStr);

  return { size, blockNum };
}

/**
 * Find next power of 2 greater than or equal to n
 */
export function nextPowerOfTwo(n: number): BlockSize {
  if (n <= MIN_BLOCK_SIZE) return MIN_BLOCK_SIZE;
  if (n >= MAX_BLOCK_SIZE) return MAX_BLOCK_SIZE;

  let power = MIN_BLOCK_SIZE;
  while (power < n) {
    power *= 2;
  }
  return power as BlockSize;
}
