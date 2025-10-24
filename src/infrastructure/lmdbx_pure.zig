/// Pure Zig FFI bindings to libmdbx.so - no C headers required
/// This file can be copied anywhere and used independently
/// Just link with liblmdbx.so at runtime

// ============================================================================
// Opaque types from libmdbx
// ============================================================================

pub const MDBX_env = opaque {};
pub const MDBX_txn = opaque {};
pub const MDBX_cursor = opaque {};
pub const MDBX_dbi = u32;

// ============================================================================
// Constants
// ============================================================================

pub const MDBX_SUCCESS: c_int = 0;
pub const MDBX_NOTFOUND: c_int = -30798;

// Environment flags
pub const MDBX_CREATE: c_uint = 0x40000;
pub const MDBX_COALESCE: c_uint = 0x2000000;
pub const MDBX_LIFORECLAIM: c_uint = 0x4000000;
pub const MDBX_NOMETASYNC: c_uint = 0x40000;
pub const MDBX_SAFE_NOSYNC: c_uint = 0x10000;

// Transaction flags
pub const MDBX_TXN_RDONLY: c_uint = 0x20000;

// Put flags
pub const MDBX_UPSERT: c_uint = 0;

// Cursor operations
pub const MDBX_FIRST: c_uint = 0;
pub const MDBX_NEXT: c_uint = 8;
pub const MDBX_SET_RANGE: c_uint = 17;

// ============================================================================
// Structures
// ============================================================================

pub const MDBX_val = extern struct {
    iov_base: ?*anyopaque,
    iov_len: usize,
};

// ============================================================================
// External functions from liblmdbx.so
// ============================================================================

pub extern "c" fn mdbx_env_create(env: *?*MDBX_env) c_int;
pub extern "c" fn mdbx_env_close(env: ?*MDBX_env) c_int;
pub extern "c" fn mdbx_env_open(env: ?*MDBX_env, path: [*:0]const u8, flags: c_uint, mode: c_uint) c_int;
pub extern "c" fn mdbx_env_set_maxreaders(env: ?*MDBX_env, readers: c_uint) c_int;
pub extern "c" fn mdbx_env_set_maxdbs(env: ?*MDBX_env, dbs: c_uint) c_int;
pub extern "c" fn mdbx_env_sync(env: ?*MDBX_env) c_int;

pub extern "c" fn mdbx_txn_begin(env: ?*MDBX_env, parent: ?*MDBX_txn, flags: c_uint, txn: *?*MDBX_txn) c_int;
pub extern "c" fn mdbx_txn_commit(txn: ?*MDBX_txn) c_int;
pub extern "c" fn mdbx_txn_abort(txn: ?*MDBX_txn) c_int;

pub extern "c" fn mdbx_dbi_open(txn: ?*MDBX_txn, name: ?[*:0]const u8, flags: c_uint, dbi: *MDBX_dbi) c_int;

pub extern "c" fn mdbx_get(txn: ?*MDBX_txn, dbi: MDBX_dbi, key: *MDBX_val, data: *MDBX_val) c_int;
pub extern "c" fn mdbx_put(txn: ?*MDBX_txn, dbi: MDBX_dbi, key: *MDBX_val, data: *MDBX_val, flags: c_uint) c_int;
pub extern "c" fn mdbx_del(txn: ?*MDBX_txn, dbi: MDBX_dbi, key: *MDBX_val, data: ?*MDBX_val) c_int;

pub extern "c" fn mdbx_cursor_open(txn: ?*MDBX_txn, dbi: MDBX_dbi, cursor: *?*MDBX_cursor) c_int;
pub extern "c" fn mdbx_cursor_close(cursor: ?*MDBX_cursor) void;
pub extern "c" fn mdbx_cursor_get(cursor: ?*MDBX_cursor, key: *MDBX_val, data: *MDBX_val, op: c_uint) c_int;
