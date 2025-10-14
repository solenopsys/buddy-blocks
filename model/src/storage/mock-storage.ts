import { IStorage } from './interfaces.js';
import { BlockMetadata, FreeListEntry } from './types.js';

/**
 * Mock in-memory storage implementation with prefix index
 * Simulates LMDB behavior with O(1) prefix lookups
 */
export class MockStorage implements IStorage {
  private data: Map<string, BlockMetadata | FreeListEntry>;
  // Index: prefix -> Set of keys (O(1) add/delete)
  private prefixIndex: Map<string, Set<string>>;

  constructor() {
    this.data = new Map();
    this.prefixIndex = new Map();
  }

  private extractPrefix(key: string): string | null {
    // Free list keys: "4k_123", "512k_45", "1m_2"
    const match = key.match(/^(\d+[km])_/);
    return match ? match[1] : null;
  }

  get(key: string): BlockMetadata | FreeListEntry | undefined {
    return this.data.get(key);
  }

  set(key: string, value: BlockMetadata | FreeListEntry): void {
    this.data.set(key, value);

    // Update prefix index for free list keys
    const prefix = this.extractPrefix(key);
    if (prefix) {
      let keys = this.prefixIndex.get(prefix);
      if (!keys) {
        keys = new Set();
        this.prefixIndex.set(prefix, keys);
      }
      keys.add(key);
    }
  }

  delete(key: string): boolean {
    const deleted = this.data.delete(key);

    if (deleted) {
      // Update prefix index
      const prefix = this.extractPrefix(key);
      if (prefix) {
        const keys = this.prefixIndex.get(prefix);
        if (keys) {
          keys.delete(key);
          if (keys.size === 0) {
            this.prefixIndex.delete(prefix);
          }
        }
      }
    }

    return deleted;
  }

  has(key: string): boolean {
    return this.data.has(key);
  }

  /**
   * Simulate LMDB cursor range scan with prefix - O(1)
   * Returns any key with this prefix (order doesn't matter)
   */
  getFirstWithPrefix(prefix: string): { key: string; value: FreeListEntry } | undefined {
    // Remove trailing underscore if present
    const cleanPrefix = prefix.endsWith('_') ? prefix.slice(0, -1) : prefix;

    const keys = this.prefixIndex.get(cleanPrefix);
    if (!keys || keys.size === 0) {
      return undefined;
    }

    // Just take any key (first from iterator)
    const key = keys.values().next().value;
    const value = this.data.get(key);

    if (value && 'buddyNum' in value) {
      return { key, value: value as FreeListEntry };
    }

    return undefined;
  }

  getAllWithPrefix(prefix: string): Array<{ key: string; value: any }> {
    const results: Array<{ key: string; value: any }> = [];

    for (const [key, value] of this.data.entries()) {
      if (key.startsWith(prefix)) {
        results.push({ key, value });
      }
    }

    return results.sort((a, b) => a.key.localeCompare(b.key));
  }

  clear(): void {
    this.data.clear();
    this.prefixIndex.clear();
  }

  /**
   * Get storage size (for debugging)
   */
  size(): number {
    return this.data.size;
  }

  /**
   * Print storage contents (for debugging)
   */
  debug(): void {
    console.log('Storage contents:');
    const entries = Array.from(this.data.entries()).sort((a, b) => a[0].localeCompare(b[0]));
    for (const [key, value] of entries) {
      console.log(`  ${key}:`, value);
    }
  }
}
