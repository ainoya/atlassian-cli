const std = @import("std");

pub const AtlassianClient = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8,
    username: []const u8,
    api_token: []const u8,
    /// Jira REST API version to address: "2", "3" or "latest".
    jira_api_version: []const u8,
    http_client: std.http.Client,
    is_cloud: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        base_url: []const u8,
        username: []const u8,
        api_token: []const u8,
        jira_api_version: []const u8,
        is_cloud: bool,
    ) AtlassianClient {
        return .{
            .allocator = allocator,
            .io = io,
            .base_url = base_url,
            .username = username,
            .api_token = api_token,
            .jira_api_version = jira_api_version,
            .http_client = std.http.Client{ .allocator = allocator, .io = io },
            .is_cloud = is_cloud,
        };
    }

    pub fn deinit(self: *AtlassianClient) void {
        self.http_client.deinit();
    }

    /// Create Basic Auth header value (base64 encoded username:token)
    fn createAuthHeader(self: *AtlassianClient, buffer: []u8) ![]const u8 {
        var auth_buffer: [1024]u8 = undefined;
        const auth_str = try std.fmt.bufPrint(&auth_buffer, "{s}:{s}", .{ self.username, self.api_token });

        // Base64 encode into separate buffer
        var encoded_buffer: [2048]u8 = undefined;
        const encoder = std.base64.standard.Encoder;
        const encoded_len = encoder.calcSize(auth_str.len);
        if (encoded_len > encoded_buffer.len) return error.BufferTooSmall;

        const encoded = encoded_buffer[0..encoded_len];
        _ = encoder.encode(encoded, auth_str);

        // Now create the final header string
        return try std.fmt.bufPrint(buffer, "Basic {s}", .{encoded});
    }

    /// Make HTTP request to Atlassian API
    pub fn makeRequest(
        self: *AtlassianClient,
        method: std.http.Method,
        endpoint: []const u8,
        query_params: ?[]const u8,
    ) ![]u8 {
        var url_buffer: [4096]u8 = undefined;
        const url = if (query_params) |params|
            try std.fmt.bufPrint(&url_buffer, "{s}{s}?{s}", .{ self.base_url, endpoint, params })
        else
            try std.fmt.bufPrint(&url_buffer, "{s}{s}", .{ self.base_url, endpoint });

        var auth_header_buffer: [2048]u8 = undefined;
        const auth_header = try self.createAuthHeader(&auth_header_buffer);

        // Allocating writer for response
        var response_writer = std.Io.Writer.Allocating.init(self.allocator);
        defer response_writer.deinit();

        const response = try self.http_client.fetch(.{
            .method = method,
            .location = .{ .url = url },
            .extra_headers = &[_]std.http.Header{
                .{ .name = "Authorization", .value = auth_header },
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "Accept", .value = "application/json" },
            },
            .response_writer = &response_writer.writer,
        });

        const status_code = @intFromEnum(response.status);
        switch (response.status) {
            .ok, .created, .accepted, .no_content => {},
            .unauthorized => {
                std.debug.print("Authentication failed ({d}). Check the configured username and API token\n", .{status_code});
                return error.AuthenticationFailed;
            },
            .forbidden => {
                std.debug.print("Permission denied ({d}). Check user permissions\n", .{status_code});
                return error.PermissionDenied;
            },
            .not_found => {
                std.debug.print("Resource not found ({d}): {s}\n", .{ status_code, endpoint });
                return error.NotFound;
            },
            else => {
                std.debug.print("HTTP error {d} for {s}\n", .{ status_code, endpoint });
                return error.HttpError;
            },
        }

        return try response_writer.toOwnedSlice();
    }
};

test "create auth header" {
    const allocator = std.testing.allocator;
    var client = AtlassianClient.init(
        allocator,
        std.Io.Threaded.global_single_threaded.io(),
        "https://test.atlassian.net",
        "test@example.com",
        "test_token",
        "3",
        true,
    );
    defer client.deinit();

    var buffer: [2048]u8 = undefined;
    const auth = try client.createAuthHeader(&buffer);
    try std.testing.expect(std.mem.startsWith(u8, auth, "Basic "));
}
