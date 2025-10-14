import { BlockMetadata, FreeListEntry } from './types.js';

/**
 * Storage interface for key-value operations (LMDB abstraction)
 */
export interface IStorage {
  /**
   * Get value by key
   */
  get(key: string): BlockMetadata | FreeListEntry | undefined;

  /**
   * Set key-value pair
   */
  set(key: string, value: BlockMetadata | FreeListEntry): void;

  /**
   * Delete key
   */
  delete(key: string): boolean;

  /**
   * Check if key exists
   */
  has(key: string): boolean;

  /**
   * Get first key with given prefix (cursor range scan)
   * Returns undefined if no key found with this prefix
   */
  getFirstWithPrefix(prefix: string): { key: string; value: FreeListEntry } | undefined;

  /**
   * Get all keys with given prefix (for debugging/testing)
   */
  getAllWithPrefix(prefix: string): Array<{ key: string; value: any }>;

  /**
   * Clear all data
   */
  clear(): void;
}

/**
 * File controller interface - only size management
 * Real data I/O goes through kernel and ring buffers, bypassing controller
 */
export interface IFileController {
  /**
   * Get current file size in bytes
   */
  getSize(): bigint;

  /**
   * Extend file by specified number of bytes
   */
  extend(bytes: bigint): void;
}
