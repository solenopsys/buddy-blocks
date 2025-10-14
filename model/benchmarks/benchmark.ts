import { BlockController } from './block-controller.js';
import { MockStorage } from './mock-storage.js';
import { MockFileController } from './mock-file-controller.js';

// Random helpers
function randomInt(min: number, max: number): number {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

function randomBlockSize(): number {
  // Random size from 100 bytes to 512KB
  return randomInt(100, 512 * 1024);
}

function benchmark() {
  const storage = new MockStorage();
  const fileController = new MockFileController();
  const controller = new BlockController(storage, fileController);

  const activeBlocks = new Set<string>();
  let totalOps = 0;
  let allocCount = 0;
  let freeCount = 0;
  let getCount = 0;

  const startTime = performance.now();
  const duration = 5000; // 5 seconds

  console.log('Starting benchmark...');
  console.log('Duration: 5 seconds');
  console.log('Operations: random allocate/free/get\n');

  while (performance.now() - startTime < duration) {
    const op = Math.random();

    if (op < 0.5 || activeBlocks.size === 0) {
      // Allocate new block (50% chance or if no blocks)
      const hash = `block_${totalOps}`;
      const dataLength = randomBlockSize();

      try {
        controller.allocate({ hash, dataLength });
        activeBlocks.add(hash);
        allocCount++;
      } catch (e) {
        // Duplicate hash, skip
      }
    } else if (op < 0.8 && activeBlocks.size > 0) {
      // Free random block (30% chance)
      const hashes = Array.from(activeBlocks);
      const hash = hashes[randomInt(0, hashes.length - 1)];

      controller.free(hash);
      activeBlocks.delete(hash);
      freeCount++;
    } else if (activeBlocks.size > 0) {
      // Get random block metadata (20% chance)
      const hashes = Array.from(activeBlocks);
      const hash = hashes[randomInt(0, hashes.length - 1)];

      controller.getBlock(hash);
      getCount++;
    }

    totalOps++;
  }

  const endTime = performance.now();
  const elapsed = (endTime - startTime) / 1000;

  const stats = controller.getStats();

  console.log('='.repeat(60));
  console.log('BENCHMARK RESULTS');
  console.log('='.repeat(60));
  console.log(`Total time:        ${elapsed.toFixed(3)}s`);
  console.log(`Total operations:  ${totalOps.toLocaleString()}`);
  console.log(`Operations/sec:    ${Math.round(totalOps / elapsed).toLocaleString()}`);
  console.log();
  console.log(`Allocations:       ${allocCount.toLocaleString()} (${(allocCount / totalOps * 100).toFixed(1)}%)`);
  console.log(`Frees:             ${freeCount.toLocaleString()} (${(freeCount / totalOps * 100).toFixed(1)}%)`);
  console.log(`Gets:              ${getCount.toLocaleString()} (${(getCount / totalOps * 100).toFixed(1)}%)`);
  console.log();
  console.log(`Active blocks:     ${activeBlocks.size.toLocaleString()}`);
  console.log(`File size:         ${(Number(stats.fileSize) / 1024 / 1024).toFixed(2)} MB`);
  console.log(`Used blocks:       ${stats.usedBlocks}`);
  console.log();

  // Show free blocks distribution
  const freeBlockSizes = Object.keys(stats.freeBlocks).sort((a, b) => {
    const sizeA = parseInt(a) * (a.includes('m') ? 1024 : 1);
    const sizeB = parseInt(b) * (b.includes('m') ? 1024 : 1);
    return sizeA - sizeB;
  });

  console.log('Free blocks distribution:');
  for (const size of freeBlockSizes) {
    console.log(`  ${size.padEnd(6)} -> ${stats.freeBlocks[size]} blocks`);
  }

  console.log();
  console.log(`Avg ops/sec:       ${Math.round(totalOps / elapsed).toLocaleString()} ops/sec`);

  // Sanity check
  if (stats.usedBlocks !== activeBlocks.size) {
    console.error('\n❌ ERROR: Block count mismatch!');
    console.error(`Expected: ${activeBlocks.size}, Got: ${stats.usedBlocks}`);
    process.exit(1);
  }

  console.log('\n✅ All checks passed!');
}

// Run benchmark
benchmark();
