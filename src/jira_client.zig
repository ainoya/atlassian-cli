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

    /// Get issue by key (e.g., "PROJECT-123")
    pub fn getIssue(self: *JiraClient, issue_key: []const u8, fields: ?[]const u8) ![]u8 {
        var params_buffer: [1024]u8 = undefined;
        const params = if (fields) |f|
            try std.fmt.bufPrint(&params_buffer, "fields={s}", .{f})
        else
            "fields=summary,description,status,assignee,reporter,labels,priority,created,updated,issuetype";

        var endpoint_buffer: [256]u8 = undefined;
        const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "/rest/api/3/issue/{s}", .{issue_key});

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

        const endpoint = "/rest/api/3/search/jql";
        return try self.client.makeRequest(.GET, endpoint, stream.getWritten());
    }

    /// Get all projects
    pub fn getProjects(self: *JiraClient) ![]u8 {
        const endpoint = "/rest/api/3/project";
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
        const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "/rest/api/3/issue/{s}/transitions", .{issue_key});
        return try self.client.makeRequest(.GET, endpoint, null);
    }

    /// Get issue comments
    pub fn getComments(self: *JiraClient, issue_key: []const u8) ![]u8 {
        var endpoint_buffer: [256]u8 = undefined;
        const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "/rest/api/3/issue/{s}/comment", .{issue_key});
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
        const endpoint = if (self.client.is_cloud) "/rest/api/3/myself" else "/rest/api/2/myself";
        return try self.client.makeRequest(.GET, endpoint, null);
    }
};
