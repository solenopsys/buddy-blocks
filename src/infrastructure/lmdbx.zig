const std = @import("std");
pub const c = @cImport({
    @cInclude("mdbx.h");
});

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
    cursor: *c.MDBX_cursor,
    txn: *c.MDBX_txn,
    owns_txn: bool,

    /// Seek to first key with given prefix
    /// Returns the first entry or null if not found
    pub fn seekPrefix(self: Cursor, allocator: std.mem.Allocator, prefix: []const u8) !?CursorEntry {
        var k = c.MDBX_val{
            .iov_base = @constCast(prefix.ptr),
            .iov_len = prefix.len,
        };
        var v: c.MDBX_val = undefined;

        const rc = c.mdbx_cursor_get(self.cursor, &k, &v, c.MDBX_SET_RANGE);
        if (rc == c.MDBX_NOTFOUND) return null;
        if (rc != c.MDBX_SUCCESS) return MdbxError.GetFailed;

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
        var k: c.MDBX_val = undefined;
        var v: c.MDBX_val = undefined;

        const rc = c.mdbx_cursor_get(self.cursor, &k, &v, c.MDBX_NEXT);
        if (rc == c.MDBX_NOTFOUND) return null;
        if (rc != c.MDBX_SUCCESS) return MdbxError.GetFailed;

        const key_data = @as([*]u8, @ptrCast(k.iov_base))[0..k.iov_len];
        const value_data = @as([*]u8, @ptrCast(v.iov_base))[0..v.iov_len];

        return CursorEntry{
            .key = try allocator.dupe(u8, key_data),
            .value = try allocator.dupe(u8, value_data),
        };
    }
};

pub const Database = struct {
    env: *c.MDBX_env,
    dbi: c.MDBX_dbi,
    current_txn: ?*c.MDBX_txn,

    pub fn open(path: [:0]const u8) !Database {
        var env: ?*c.MDBX_env = null;

        var rc = c.mdbx_env_create(&env);
        if (rc != c.MDBX_SUCCESS) return MdbxError.CreateFailed;

        // Set max readers and DBs
        _ = c.mdbx_env_set_maxreaders(env, 126);
        _ = c.mdbx_env_set_maxdbs(env, 128);

        rc = c.mdbx_env_open(env, path.ptr, c.MDBX_CREATE | c.MDBX_COALESCE | c.MDBX_LIFORECLAIM | c.MDBX_NOMETASYNC | c.MDBX_SAFE_NOSYNC, 0o664);
        if (rc != c.MDBX_SUCCESS) {
            _ = c.mdbx_env_close(env);
            return MdbxError.OpenFailed;
        }

        var txn: ?*c.MDBX_txn = null;
        rc = c.mdbx_txn_begin(env, null, 0, &txn);
        if (rc != c.MDBX_SUCCESS) {
            _ = c.mdbx_env_close(env);
            return MdbxError.TxnBeginFailed;
        }

        var dbi: c.MDBX_dbi = undefined;
        rc = c.mdbx_dbi_open(txn, null, c.MDBX_CREATE, &dbi);
        if (rc != c.MDBX_SUCCESS) {
            _ = c.mdbx_txn_abort(txn);
            _ = c.mdbx_env_close(env);
            return MdbxError.DbiOpenFailed;
        }

        rc = c.mdbx_txn_commit(txn);
        if (rc != c.MDBX_SUCCESS) {
            _ = c.mdbx_env_close(env);
            return MdbxError.TxnCommitFailed;
        }

        return Database{
            .env = env.?,
            .dbi = dbi,
            .current_txn = null,
        };
    }

    pub fn close(self: *Database) void {
        _ = c.mdbx_env_close(self.env);
    }

    pub fn put(self: *Database, key: []const u8, value: []const u8) !void {
        const use_current = self.current_txn != null;
        var txn: ?*c.MDBX_txn = self.current_txn;

        if (!use_current) {
            const rc = c.mdbx_txn_begin(self.env, null, 0, &txn);
            if (rc != c.MDBX_SUCCESS) return MdbxError.TxnBeginFailed;
        }

        var k = c.MDBX_val{
            .iov_base = @constCast(key.ptr),
            .iov_len = key.len,
        };
        var v = c.MDBX_val{
            .iov_base = @constCast(value.ptr),
            .iov_len = value.len,
        };

        var rc = c.mdbx_put(txn, self.dbi, &k, &v, c.MDBX_UPSERT);
        if (rc != c.MDBX_SUCCESS) {
            if (!use_current) _ = c.mdbx_txn_abort(txn);
            return MdbxError.PutFailed;
        }

        if (!use_current) {
            rc = c.mdbx_txn_commit(txn);
            if (rc != c.MDBX_SUCCESS) return MdbxError.TxnCommitFailed;
        }
    }

    pub fn get(self: *Database, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
        const use_current = self.current_txn != null;
        var txn: ?*c.MDBX_txn = self.current_txn;

        if (!use_current) {
            const rc = c.mdbx_txn_begin(self.env, null, c.MDBX_TXN_RDONLY, &txn);
            if (rc != c.MDBX_SUCCESS) return MdbxError.TxnBeginFailed;
        }
        defer {
            if (!use_current) _ = c.mdbx_txn_abort(txn);
        }

        var k = c.MDBX_val{
            .iov_base = @constCast(key.ptr),
            .iov_len = key.len,
        };
        var v: c.MDBX_val = undefined;

        const rc = c.mdbx_get(txn, self.dbi, &k, &v);
        if (rc == c.MDBX_NOTFOUND) return null;
        if (rc != c.MDBX_SUCCESS) return MdbxError.GetFailed;

        const data = @as([*]u8, @ptrCast(v.iov_base))[0..v.iov_len];
        const result = try allocator.dupe(u8, data);
        return result;
    }

    pub fn delete(self: *Database, key: []const u8) !void {
        const use_current = self.current_txn != null;
        var txn: ?*c.MDBX_txn = self.current_txn;

        if (!use_current) {
            const rc = c.mdbx_txn_begin(self.env, null, 0, &txn);
            if (rc != c.MDBX_SUCCESS) return MdbxError.TxnBeginFailed;
        }

        var k = c.MDBX_val{
            .iov_base = @constCast(key.ptr),
            .iov_len = key.len,
        };

        var rc = c.mdbx_del(txn, self.dbi, &k, null);
        if (rc == c.MDBX_NOTFOUND) {
            if (!use_current) _ = c.mdbx_txn_abort(txn);
            return MdbxError.NotFound;
        }
        if (rc != c.MDBX_SUCCESS) {
            if (!use_current) _ = c.mdbx_txn_abort(txn);
            return MdbxError.DeleteFailed;
        }

        if (!use_current) {
            rc = c.mdbx_txn_commit(txn);
            if (rc != c.MDBX_SUCCESS) return MdbxError.TxnCommitFailed;
        }
    }

    pub fn flush(self: *Database) !void {
        const rc = c.mdbx_env_sync(self.env);
        if (rc != c.MDBX_SUCCESS) return MdbxError.TxnCommitFailed;
    }

    pub fn beginTransaction(self: *Database) !void {
        if (self.current_txn != null) return; // Already in transaction

        var txn: ?*c.MDBX_txn = null;
        const rc = c.mdbx_txn_begin(self.env, null, 0, &txn);
        if (rc != c.MDBX_SUCCESS) return MdbxError.TxnBeginFailed;
        self.current_txn = txn;
    }

    pub fn commitTransaction(self: *Database) !void {
        if (self.current_txn) |txn| {
            const rc = c.mdbx_txn_commit(txn);
            self.current_txn = null;
            if (rc != c.MDBX_SUCCESS) return MdbxError.TxnCommitFailed;
        }
    }

    pub fn abortTransaction(self: *Database) void {
        if (self.current_txn) |txn| {
            _ = c.mdbx_txn_abort(txn);
            self.current_txn = null;
        }
    }

    pub fn openCursor(self: *Database) !Cursor {
        const use_current = self.current_txn != null;
        var txn: ?*c.MDBX_txn = self.current_txn;

        if (!use_current) {
            const rc = c.mdbx_txn_begin(self.env, null, c.MDBX_TXN_RDONLY, &txn);
            if (rc != c.MDBX_SUCCESS) return MdbxError.TxnBeginFailed;
        }

        var cursor: ?*c.MDBX_cursor = null;
        const rc = c.mdbx_cursor_open(txn, self.dbi, &cursor);
        if (rc != c.MDBX_SUCCESS) {
            if (!use_current) _ = c.mdbx_txn_abort(txn);
            return MdbxError.CursorOpenFailed;
        }

        return Cursor{
            .cursor = cursor.?,
            .txn = txn.?,
            .owns_txn = !use_current,
        };
    }

    pub fn closeCursor(cursor: Cursor) void {
        c.mdbx_cursor_close(cursor.cursor);
        if (cursor.owns_txn) {
            _ = c.mdbx_txn_abort(cursor.txn);
        }
    }
};
