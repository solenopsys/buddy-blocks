import { IFileController } from './interfaces.js';

/**
 * Mock in-memory file controller - only tracks size
 * Real I/O happens outside of controller (through kernel/io_uring)
 */
export class MockFileController implements IFileController {
  private currentSize: bigint;
  private data: Uint8Array; // Only for testing/verification

  constructor(initialSize: bigint = 0n) {
    this.currentSize = initialSize;
    this.data = new Uint8Array(Number(initialSize));
  }

  getSize(): bigint {
    return this.currentSize;
  }

  extend(bytes: bigint): void {
    const newSize = this.currentSize + bytes;
    const newData = new Uint8Array(Number(newSize));

    // Copy existing data
    newData.set(this.data);

    this.data = newData;
    this.currentSize = newSize;
  }

  // Test helpers (not part of interface, simulate external I/O)

  write(offset: bigint, data: Uint8Array): void {
    const offsetNum = Number(offset);
    const endPos = offsetNum + data.length;

    if (endPos > this.data.length) {
      throw new Error(`Write beyond file size: offset=${offset}, dataLength=${data.length}, fileSize=${this.currentSize}`);
    }

    this.data.set(data, offsetNum);
  }

  read(offset: bigint, length: number): Uint8Array {
    const offsetNum = Number(offset);
    const endPos = offsetNum + length;

    if (endPos > this.data.length) {
      throw new Error(`Read beyond file size: offset=${offset}, length=${length}, fileSize=${this.currentSize}`);
    }

    return this.data.slice(offsetNum, endPos);
  }
}
