const std = @import("std");
const AtlassianClient = @import("atlassian_client.zig").AtlassianClient;
const urlEncode = @import("url_encoder.zig").urlEncode;

pub const JiraClient = struct {
    client: *AtlassianClient,
    allocator: std.mem.Allocator,

    pub fn init(client: *AtlassianClient, allocator: std.mem.Allocator) JiraClient {
        return .{
            .client = client,
            .allocator = allocator,
        };
    }

    fn apiVersion(self: *const JiraClient) []const u8 {
        return self.client.jira_api_version;
    }

    fn writeApiPath(self: *const JiraClient, buffer: []u8, suffix: []const u8) ![]const u8 {
        return try std.fmt.bufPrint(buffer, "/rest/api/{s}{s}", .{ self.apiVersion(), suffix });
    }

    fn writeSearchEndpoint(self: *const JiraClient, buffer: []u8) ![]const u8 {
        return if (self.client.is_cloud and std.mem.eql(u8, self.apiVersion(), "3"))
            "/rest/api/3/search/jql"
        else
            try self.writeApiPath(buffer, "/search");
    }

    /// Get issue by key (e.g., "PROJECT-123")
    pub fn getIssue(self: *JiraClient, issue_key: []const u8, fields: ?[]const u8) ![]u8 {
        var params_buffer: [1024]u8 = undefined;
        const params = if (fields) |f|
            try std.fmt.bufPrint(&params_buffer, "fields={s}", .{f})
        else
            "fields=summary,description,status,assignee,reporter,labels,priority,created,updated,issuetype";

        var endpoint_buffer: [256]u8 = undefined;
        const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "/rest/api/{s}/issue/{s}", .{ self.apiVersion(), issue_key });

        return try self.client.makeRequest(.GET, endpoint, params);
    }

    /// Search issues using JQL (Jira Query Language)
    pub fn search(self: *JiraClient, jql: []const u8, fields: ?[]const u8, max_results: usize) ![]u8 {
        // URL encode JQL query
        const encoded_jql = try urlEncode(self.allocator, jql);
        defer self.allocator.free(encoded_jql);

        var params_buffer: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&params_buffer);
        var writer = stream.writer();

        try writer.print("jql={s}", .{encoded_jql});

        if (fields) |f| {
            try writer.print("&fields={s}", .{f});
        } else {
            try writer.writeAll("&fields=summary,description,status,assignee,reporter,labels,priority,created,updated,issuetype");
        }

        try writer.print("&maxResults={d}", .{max_results});

        var endpoint_buffer: [256]u8 = undefined;
        const endpoint = try self.writeSearchEndpoint(&endpoint_buffer);
        return try self.client.makeRequest(.GET, endpoint, stream.getWritten());
    }

    /// Get all projects
    pub fn getProjects(self: *JiraClient) ![]u8 {
        var endpoint_buffer: [256]u8 = undefined;
        const endpoint = try self.writeApiPath(&endpoint_buffer, "/project");
        return try self.client.makeRequest(.GET, endpoint, null);
    }

    /// Get project issues
    pub fn getProjectIssues(self: *JiraClient, project_key: []const u8, max_results: usize) ![]u8 {
        var jql_buffer: [256]u8 = undefined;
        const jql = try std.fmt.bufPrint(&jql_buffer, "project={s} ORDER BY created DESC", .{project_key});
        return try self.search(jql, null, max_results);
    }

    /// Get issue transitions (workflow states)
    pub fn getTransitions(self: *JiraClient, issue_key: []const u8) ![]u8 {
        var endpoint_buffer: [256]u8 = undefined;
        const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "/rest/api/{s}/issue/{s}/transitions", .{ self.apiVersion(), issue_key });
        return try self.client.makeRequest(.GET, endpoint, null);
    }

    /// Get issue comments
    pub fn getComments(self: *JiraClient, issue_key: []const u8) ![]u8 {
        var endpoint_buffer: [256]u8 = undefined;
        const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "/rest/api/{s}/issue/{s}/comment", .{ self.apiVersion(), issue_key });
        return try self.client.makeRequest(.GET, endpoint, null);
    }

    /// Get agile boards
    pub fn getBoards(self: *JiraClient, board_type: ?[]const u8, max_results: usize) ![]u8 {
        var params_buffer: [512]u8 = undefined;
        const params = if (board_type) |bt|
            try std.fmt.bufPrint(&params_buffer, "type={s}&maxResults={d}", .{ bt, max_results })
        else
            try std.fmt.bufPrint(&params_buffer, "maxResults={d}", .{max_results});

        const endpoint = "/rest/agile/1.0/board";
        return try self.client.makeRequest(.GET, endpoint, params);
    }

    /// Get sprints from board
    pub fn getSprints(self: *JiraClient, board_id: []const u8, state: ?[]const u8) ![]u8 {
        var endpoint_buffer: [256]u8 = undefined;
        const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "/rest/agile/1.0/board/{s}/sprint", .{board_id});

        var params_buffer: [256]u8 = undefined;
        const params = if (state) |s|
            try std.fmt.bufPrint(&params_buffer, "state={s}", .{s})
        else
            null;

        return try self.client.makeRequest(.GET, endpoint, params);
    }

    /// Get issues in sprint
    pub fn getSprintIssues(self: *JiraClient, sprint_id: []const u8, max_results: usize) ![]u8 {
        var endpoint_buffer: [256]u8 = undefined;
        const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "/rest/agile/1.0/sprint/{s}/issue", .{sprint_id});

        var params_buffer: [256]u8 = undefined;
        const params = try std.fmt.bufPrint(&params_buffer, "maxResults={d}", .{max_results});

        return try self.client.makeRequest(.GET, endpoint, params);
    }

    /// Get current user profile
    pub fn getCurrentUser(self: *JiraClient) ![]u8 {
        var endpoint_buffer: [256]u8 = undefined;
        const endpoint = try self.writeApiPath(&endpoint_buffer, "/myself");
        return try self.client.makeRequest(.GET, endpoint, null);
    }
};

test "jira client chooses server endpoints when cloud is disabled" {
    const allocator = std.testing.allocator;

    var client = AtlassianClient.init(
        allocator,
        "https://jira.example.com",
        "user",
        "token",
        "2",
        false,
    );
    defer client.deinit();

    var jira = JiraClient.init(&client, allocator);

    try std.testing.expectEqualStrings("2", jira.apiVersion());
}

test "jira client allows latest api version override" {
    const allocator = std.testing.allocator;

    var client = AtlassianClient.init(
        allocator,
        "https://jira.example.com",
        "user",
        "token",
        "latest",
        false,
    );
    defer client.deinit();

    var jira = JiraClient.init(&client, allocator);

    var path_buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/rest/api/latest", try jira.writeApiPath(&path_buffer, ""));

    var search_buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/rest/api/latest/search", try jira.writeSearchEndpoint(&search_buffer));
}
