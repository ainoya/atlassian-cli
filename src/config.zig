const std = @import("std");
const builtin = @import("builtin");

pub const Config = struct {
    atlassian_username: ?[]const u8 = null,
    atlassian_api_token: ?[]const u8 = null,
    atlassian_url: ?[]const u8 = null,

    // Allocator used for internal strings
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Config {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Config) void {
        if (self.atlassian_username) |u| self.allocator.free(u);
        if (self.atlassian_api_token) |t| self.allocator.free(t);
        if (self.atlassian_url) |u| self.allocator.free(u);
    }

    pub fn load(self: *Config) !void {
        const config_path = try getConfigPath(self.allocator);
        defer self.allocator.free(config_path);

        const file = std.fs.openFileAbsolute(config_path, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
        defer parsed.deinit();

        const root = parsed.value.object;

        if (root.get("atlassian_username")) |val| {
            if (val == .string) {
                if (self.atlassian_username) |u| self.allocator.free(u);
                self.atlassian_username = try self.allocator.dupe(u8, val.string);
            }
        }
        if (root.get("atlassian_api_token")) |val| {
            if (val == .string) {
                if (self.atlassian_api_token) |t| self.allocator.free(t);
                self.atlassian_api_token = try self.allocator.dupe(u8, val.string);
            }
        }
        if (root.get("atlassian_url")) |val| {
            if (val == .string) {
                if (self.atlassian_url) |u| self.allocator.free(u);
                self.atlassian_url = try self.allocator.dupe(u8, val.string);
            }
        }
    }

    pub fn save(self: *Config) !void {
        const config_path = try getConfigPath(self.allocator);
        defer self.allocator.free(config_path);

        // Ensure directory exists
        if (std.fs.path.dirname(config_path)) |dir| {
            try std.fs.cwd().makePath(dir);
        }

        const file = try std.fs.createFileAbsolute(config_path, .{
            .read = true,
            .truncate = true,
            .mode = 0o600,
        });
        defer file.close();

        var list = std.ArrayListUnmanaged(u8){};
        defer list.deinit(self.allocator);
        const writer = list.writer(self.allocator);

        try writer.writeAll("{\n");
        var first = true;

        if (self.atlassian_username) |u| {
            if (!first) try writer.writeAll(",\n");
            try writer.writeAll("  \"atlassian_username\": \"");
            try jsonStringify(u, writer);
            try writer.writeAll("\"");
            first = false;
        }
        if (self.atlassian_api_token) |t| {
            if (!first) try writer.writeAll(",\n");
            try writer.writeAll("  \"atlassian_api_token\": \"");
            try jsonStringify(t, writer);
            try writer.writeAll("\"");
            first = false;
        }
        if (self.atlassian_url) |u| {
            if (!first) try writer.writeAll(",\n");
            try writer.writeAll("  \"atlassian_url\": \"");
            try jsonStringify(u, writer);
            try writer.writeAll("\"");
            first = false;
        }
        try writer.writeAll("\n}");

        try file.writeAll(list.items);
    }

    fn jsonStringify(val: []const u8, writer: anytype) !void {
        for (val) |c| {
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => try writer.writeByte(c),
            }
        }
    }

    pub fn set(self: *Config, key: []const u8, value: []const u8) !void {
        if (std.mem.eql(u8, key, "atlassian_username")) {
            if (self.atlassian_username) |u| self.allocator.free(u);
            self.atlassian_username = try self.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "atlassian_api_token")) {
            if (self.atlassian_api_token) |t| self.allocator.free(t);
            self.atlassian_api_token = try self.allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "atlassian_url")) {
            if (self.atlassian_url) |u| self.allocator.free(u);
            self.atlassian_url = try self.allocator.dupe(u8, value);
        } else {
            return error.InvalidConfigKey;
        }
    }

    pub fn get(self: *Config, key: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, key, "atlassian_username")) return self.atlassian_username;
        if (std.mem.eql(u8, key, "atlassian_api_token")) return self.atlassian_api_token;
        if (std.mem.eql(u8, key, "atlassian_url")) return self.atlassian_url;
        return null;
    }
};

fn getConfigPath(allocator: std.mem.Allocator) ![]u8 {
    const env_home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| {
        if (builtin.os.tag == .windows) {
            return std.process.getEnvVarOwned(allocator, "USERPROFILE");
        }
        return err;
    };
    defer allocator.free(env_home);

    return std.fs.path.join(allocator, &[_][]const u8{ env_home, ".config", "atlassian-cli", "config.json" });
}

/// Resolves a configuration value by prioritizing the environment variable.
/// Returns a duplicated string that must be freed by the caller, or null/error.
pub fn resolve(allocator: std.mem.Allocator, env_val: ?[]const u8, config_val: ?[]const u8, error_if_missing: bool) !?[]u8 {
    if (env_val) |v| {
        if (v.len > 0) return try allocator.dupe(u8, v);
    }
    if (config_val) |v| {
        if (v.len > 0) return try allocator.dupe(u8, v);
    }

    if (error_if_missing) {
        return error.ConfigurationMissing;
    }
    return null;
}

test "resolve precedence" {
    const allocator = std.testing.allocator;

    // Case 1: Env set, Config set -> Env wins
    {
        const env = "env-value";
        const conf = "config-value";
        const result = try resolve(allocator, env, conf, true);
        defer allocator.free(result.?);
        try std.testing.expectEqualStrings(env, result.?);
    }

    // Case 2: Env set, Config null -> Env wins
    {
        const env = "env-value";
        const conf: ?[]const u8 = null;
        const result = try resolve(allocator, env, conf, true);
        defer allocator.free(result.?);
        try std.testing.expectEqualStrings(env, result.?);
    }

    // Case 3: Env null, Config set -> Config wins
    {
        const env: ?[]const u8 = null;
        const conf = "config-value";
        const result = try resolve(allocator, env, conf, true);
        defer allocator.free(result.?);
        try std.testing.expectEqualStrings(conf, result.?);
    }

    // Case 4: Both null, error_if_missing=true -> Error
    {
        const env: ?[]const u8 = null;
        const conf: ?[]const u8 = null;
        try std.testing.expectError(error.ConfigurationMissing, resolve(allocator, env, conf, true));
    }

    // Case 5: Both null, error_if_missing=false -> Null
    {
        const env: ?[]const u8 = null;
        const conf: ?[]const u8 = null;
        const result = try resolve(allocator, env, conf, false);
        try std.testing.expect(result == null);
    }
}
