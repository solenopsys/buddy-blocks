import { open } from 'lmdb';
import { IStorage } from './interfaces.js';
import { BlockMetadata, FreeListEntry } from './types.js';

/**
 * Real LMDB storage implementation
 */
export class LMDBStorage implements IStorage {
  private db: any;

  constructor(path: string = './data/fastblock.lmdb') {
    this.db = open({
      path,
      compression: false,
    });
  }

  get(key: string): BlockMetadata | FreeListEntry | undefined {
    return this.db.get(key);
  }

  set(key: string, value: BlockMetadata | FreeListEntry): void {
    // Use immediate write - will be slow but simple
    this.db.putSync(key, value);
  }

  delete(key: string): boolean {
    return this.db.removeSync(key);
  }

  has(key: string): boolean {
    return this.db.get(key) !== undefined;
  }

  /**
   * LMDB cursor range scan with prefix - O(1)
   */
  getFirstWithPrefix(prefix: string): { key: string; value: FreeListEntry } | undefined {
    // Use LMDB range query
    const range = this.db.getRange({
      start: prefix,
      end: prefix + '\xFF',
      limit: 1,
    });

    for (const { key, value } of range) {
      if (value && typeof value === 'object' && 'buddyNum' in value) {
        return { key, value: value as FreeListEntry };
      }
    }

    return undefined;
  }

  getAllWithPrefix(prefix: string): Array<{ key: string; value: any }> {
    const results: Array<{ key: string; value: any }> = [];

    const range = this.db.getRange({
      start: prefix,
      end: prefix + '\xFF',
    });

    for (const { key, value } of range) {
      results.push({ key, value });
    }

    return results;
  }

  clear(): void {
    this.db.clearSync();
  }

  close(): void {
    this.db.close();
  }

  // Batch API for performance
  transaction(fn: () => void): void {
    this.db.transactionSync(fn);
  }

  getDB() {
    return this.db;
  }
}
