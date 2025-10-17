/// Wrapper around buddy_allocator module
/// Re-exports types from the external buddy_allocator module

const buddy_mod = @import("buddy_allocator");

// Re-export core types from buddy_allocator module
pub const BuddyAllocator = buddy_mod.BuddyAllocator;
pub const IFileController = buddy_mod.IFileController;
pub const SimpleFileController = buddy_mod.SimpleFileController;
pub const BuddyAllocatorError = buddy_mod.BuddyAllocatorError;

// Re-export lmdbx
pub const lmdbx = buddy_mod.lmdbx;

// Re-export types module with all helpers
pub const types = buddy_mod.types;
pub const BlockSize = types.BlockSize;
pub const BlockMetadata = types.BlockMetadata;
pub const makeFreeListKey = types.makeFreeListKey;
pub const parseFreeListKey = types.parseFreeListKey;
pub const nextPowerOfTwo = types.nextPowerOfTwo;
pub const MACRO_BLOCK_SIZE = types.MACRO_BLOCK_SIZE;
pub const MIN_BLOCK_SIZE = types.MIN_BLOCK_SIZE;
pub const MAX_BLOCK_SIZE = types.MAX_BLOCK_SIZE;
