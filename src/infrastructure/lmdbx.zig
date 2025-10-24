/// High-level Zig API for LMDBX - pure Zig types, no C headers
const std = @import("std");
const ffi = @import("lmdbx_pure.zig");

pub const MdbxError = error{
    CreateFailed,
    OpenFailed,
    TxnBeginFailed,
    TxnCommitFailed,
    DbiOpenFailed,
    PutFailed,
    GetFailed,
    NotFound,
    DeleteFailed,
    CursorOpenFailed,
};

pub const CursorEntry = struct {
    key: []const u8,
    value: []const u8,
};

pub const Cursor = struct {
    cursor: *ffi.MDBX_cursor,
    txn: *ffi.MDBX_txn,
    owns_txn: bool,

    /// Seek to first key with given prefix
    /// Returns the first entry or null if not found
    pub fn seekPrefix(self: Cursor, allocator: std.mem.Allocator, prefix: []const u8) !?CursorEntry {
        var k = ffi.MDBX_val{
            .iov_base = @constCast(prefix.ptr),
            .iov_len = prefix.len,
        };
        var v: ffi.MDBX_val = undefined;

        const rc = ffi.mdbx_cursor_get(self.cursor, &k, &v, ffi.MDBX_SET_RANGE);
        if (rc == ffi.MDBX_NOTFOUND) return null;
        if (rc != ffi.MDBX_SUCCESS) return MdbxError.GetFailed;

        const key_data = @as([*]u8, @ptrCast(k.iov_base))[0..k.iov_len];
        const value_data = @as([*]u8, @ptrCast(v.iov_base))[0..v.iov_len];

        // Check if key starts with prefix
        if (key_data.len < prefix.len or !std.mem.eql(u8, key_data[0..prefix.len], prefix)) {
            return null;
        }

        return CursorEntry{
            .key = try allocator.dupe(u8, key_data),
            .value = try allocator.dupe(u8, value_data),
        };
    }

    /// Move to next entry
    /// Returns the next entry or null if no more entries
    pub fn next(self: Cursor, allocator: std.mem.Allocator) !?CursorEntry {
        var k: ffi.MDBX_val = undefined;
        var v: ffi.MDBX_val = undefined;

        const rc = ffi.mdbx_cursor_get(self.cursor, &k, &v, ffi.MDBX_NEXT);
        if (rc == ffi.MDBX_NOTFOUND) return null;
        if (rc != ffi.MDBX_SUCCESS) return MdbxError.GetFailed;

        const key_data = @as([*]u8, @ptrCast(k.iov_base))[0..k.iov_len];
        const value_data = @as([*]u8, @ptrCast(v.iov_base))[0..v.iov_len];

        return CursorEntry{
            .key = try allocator.dupe(u8, key_data),
            .value = try allocator.dupe(u8, value_data),
        };
    }
};

pub const Database = struct {
    env: *ffi.MDBX_env,
    dbi: ffi.MDBX_dbi,
    current_txn: ?*ffi.MDBX_txn,

    pub fn open(path: [:0]const u8) !Database {
        var env: ?*ffi.MDBX_env = null;

        var rc = ffi.mdbx_env_create(&env);
        if (rc != ffi.MDBX_SUCCESS) return MdbxError.CreateFailed;

        // Set max readers and DBs
        _ = ffi.mdbx_env_set_maxreaders(env, 126);
        _ = ffi.mdbx_env_set_maxdbs(env, 128);

        rc = ffi.mdbx_env_open(env, path.ptr, ffi.MDBX_CREATE | ffi.MDBX_COALESCE | ffi.MDBX_LIFORECLAIM | ffi.MDBX_NOMETASYNC | ffi.MDBX_SAFE_NOSYNC, 0o664);
        if (rc != ffi.MDBX_SUCCESS) {
            _ = ffi.mdbx_env_close(env);
            return MdbxError.OpenFailed;
        }

        var txn: ?*ffi.MDBX_txn = null;
        rc = ffi.mdbx_txn_begin(env, null, 0, &txn);
        if (rc != ffi.MDBX_SUCCESS) {
            _ = ffi.mdbx_env_close(env);
            return MdbxError.TxnBeginFailed;
        }

        var dbi: ffi.MDBX_dbi = undefined;
        rc = ffi.mdbx_dbi_open(txn, null, ffi.MDBX_CREATE, &dbi);
        if (rc != ffi.MDBX_SUCCESS) {
            _ = ffi.mdbx_txn_abort(txn);
            _ = ffi.mdbx_env_close(env);
            return MdbxError.DbiOpenFailed;
        }

        rc = ffi.mdbx_txn_commit(txn);
        if (rc != ffi.MDBX_SUCCESS) {
            _ = ffi.mdbx_env_close(env);
            return MdbxError.TxnCommitFailed;
        }

        return Database{
            .env = env.?,
            .dbi = dbi,
            .current_txn = null,
        };
    }

    pub fn close(self: *Database) void {
        _ = ffi.mdbx_env_close(self.env);
    }

    pub fn put(self: *Database, key: []const u8, value: []const u8) !void {
        const use_current = self.current_txn != null;
        var txn: ?*ffi.MDBX_txn = self.current_txn;

        if (!use_current) {
            const rc = ffi.mdbx_txn_begin(self.env, null, 0, &txn);
            if (rc != ffi.MDBX_SUCCESS) return MdbxError.TxnBeginFailed;
        }

        var k = ffi.MDBX_val{
            .iov_base = @constCast(key.ptr),
            .iov_len = key.len,
        };
        var v = ffi.MDBX_val{
            .iov_base = @constCast(value.ptr),
            .iov_len = value.len,
        };

        var rc = ffi.mdbx_put(txn, self.dbi, &k, &v, ffi.MDBX_UPSERT);
        if (rc != ffi.MDBX_SUCCESS) {
            if (!use_current) _ = ffi.mdbx_txn_abort(txn);
            return MdbxError.PutFailed;
        }

        if (!use_current) {
            rc = ffi.mdbx_txn_commit(txn);
            if (rc != ffi.MDBX_SUCCESS) return MdbxError.TxnCommitFailed;
        }
    }

    pub fn get(self: *Database, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
        const use_current = self.current_txn != null;
        var txn: ?*ffi.MDBX_txn = self.current_txn;

        if (!use_current) {
            const rc = ffi.mdbx_txn_begin(self.env, null, ffi.MDBX_TXN_RDONLY, &txn);
            if (rc != ffi.MDBX_SUCCESS) return MdbxError.TxnBeginFailed;
        }
        defer {
            if (!use_current) _ = ffi.mdbx_txn_abort(txn);
        }

        var k = ffi.MDBX_val{
            .iov_base = @constCast(key.ptr),
            .iov_len = key.len,
        };
        var v: ffi.MDBX_val = undefined;

        const rc = ffi.mdbx_get(txn, self.dbi, &k, &v);
        if (rc == ffi.MDBX_NOTFOUND) return null;
        if (rc != ffi.MDBX_SUCCESS) return MdbxError.GetFailed;

        const data = @as([*]u8, @ptrCast(v.iov_base))[0..v.iov_len];
        const result = try allocator.dupe(u8, data);
        return result;
    }

    pub fn delete(self: *Database, key: []const u8) !void {
        const use_current = self.current_txn != null;
        var txn: ?*ffi.MDBX_txn = self.current_txn;

        if (!use_current) {
            const rc = ffi.mdbx_txn_begin(self.env, null, 0, &txn);
            if (rc != ffi.MDBX_SUCCESS) return MdbxError.TxnBeginFailed;
        }

        var k = ffi.MDBX_val{
            .iov_base = @constCast(key.ptr),
            .iov_len = key.len,
        };

        var rc = ffi.mdbx_del(txn, self.dbi, &k, null);
        if (rc == ffi.MDBX_NOTFOUND) {
            if (!use_current) _ = ffi.mdbx_txn_abort(txn);
            return MdbxError.NotFound;
        }
        if (rc != ffi.MDBX_SUCCESS) {
            if (!use_current) _ = ffi.mdbx_txn_abort(txn);
            return MdbxError.DeleteFailed;
        }

        if (!use_current) {
            rc = ffi.mdbx_txn_commit(txn);
            if (rc != ffi.MDBX_SUCCESS) return MdbxError.TxnCommitFailed;
        }
    }

    pub fn flush(self: *Database) !void {
        const rc = ffi.mdbx_env_sync(self.env);
        if (rc != ffi.MDBX_SUCCESS) return MdbxError.TxnCommitFailed;
    }

    pub fn beginTransaction(self: *Database) !void {
        if (self.current_txn != null) return; // Already in transaction

        var txn: ?*ffi.MDBX_txn = null;
        const rc = ffi.mdbx_txn_begin(self.env, null, 0, &txn);
        if (rc != ffi.MDBX_SUCCESS) return MdbxError.TxnBeginFailed;
        self.current_txn = txn;
    }

    pub fn commitTransaction(self: *Database) !void {
        if (self.current_txn) |txn| {
            const rc = ffi.mdbx_txn_commit(txn);
            self.current_txn = null;
            if (rc != ffi.MDBX_SUCCESS) return MdbxError.TxnCommitFailed;
        }
    }

    pub fn abortTransaction(self: *Database) void {
        if (self.current_txn) |txn| {
            _ = ffi.mdbx_txn_abort(txn);
            self.current_txn = null;
        }
    }

    pub fn openCursor(self: *Database) !Cursor {
        const use_current = self.current_txn != null;
        var txn: ?*ffi.MDBX_txn = self.current_txn;

        if (!use_current) {
            const rc = ffi.mdbx_txn_begin(self.env, null, ffi.MDBX_TXN_RDONLY, &txn);
            if (rc != ffi.MDBX_SUCCESS) return MdbxError.TxnBeginFailed;
        }

        var cursor: ?*ffi.MDBX_cursor = null;
        const rc = ffi.mdbx_cursor_open(txn, self.dbi, &cursor);
        if (rc != ffi.MDBX_SUCCESS) {
            if (!use_current) _ = ffi.mdbx_txn_abort(txn);
            return MdbxError.CursorOpenFailed;
        }

        return Cursor{
            .cursor = cursor.?,
            .txn = txn.?,
            .owns_txn = !use_current,
        };
    }

    pub fn closeCursor(cursor: Cursor) void {
        ffi.mdbx_cursor_close(cursor.cursor);
        if (cursor.owns_txn) {
            _ = ffi.mdbx_txn_abort(cursor.txn);
        }
    }
};
