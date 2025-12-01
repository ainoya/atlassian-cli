const std = @import("std");
const AtlassianClient = @import("atlassian_client.zig").AtlassianClient;
const urlEncode = @import("url_encoder.zig").urlEncode;

pub const ConfluenceClient = struct {
    client: *AtlassianClient,
    allocator: std.mem.Allocator,
    base_path: []const u8,

    pub fn init(client: *AtlassianClient, allocator: std.mem.Allocator, base_path: []const u8) ConfluenceClient {
        return .{
            .client = client,
            .allocator = allocator,
            .base_path = base_path,
        };
    }

    /// Build full endpoint with base path
    fn buildEndpoint(self: *ConfluenceClient, buffer: []u8, api_path: []const u8) ![]const u8 {
        return try std.fmt.bufPrint(buffer, "{s}{s}", .{ self.base_path, api_path });
    }

    /// Search Confluence using CQL (Confluence Query Language)
    pub fn search(self: *ConfluenceClient, cql: []const u8, limit: usize) ![]u8 {
        // URL encode the CQL query
        const encoded_cql = try urlEncode(self.allocator, cql);
        defer self.allocator.free(encoded_cql);

        var params_buffer: [4096]u8 = undefined;
        const params = try std.fmt.bufPrint(&params_buffer, "cql={s}&limit={d}&expand=space,version,body.storage", .{ encoded_cql, limit });

        var endpoint_buffer: [512]u8 = undefined;
        const endpoint = try self.buildEndpoint(&endpoint_buffer, "/rest/api/content/search");
        return try self.client.makeRequest(.GET, endpoint, params);
    }

    /// Get page by ID with content
    pub fn getPage(self: *ConfluenceClient, page_id: []const u8) ![]u8 {
        var api_path_buffer: [256]u8 = undefined;
        const api_path = try std.fmt.bufPrint(&api_path_buffer, "/rest/api/content/{s}", .{page_id});

        var endpoint_buffer: [512]u8 = undefined;
        const endpoint = try self.buildEndpoint(&endpoint_buffer, api_path);

        const params = "expand=body.storage,version,space,children.attachment,history";
        return try self.client.makeRequest(.GET, endpoint, params);
    }

    /// Get page by title and space
    pub fn getPageByTitle(self: *ConfluenceClient, space_key: []const u8, title: []const u8) ![]u8 {
        const encoded_title = try urlEncode(self.allocator, title);
        defer self.allocator.free(encoded_title);

        var params_buffer: [2048]u8 = undefined;
        const params = try std.fmt.bufPrint(
            &params_buffer,
            "spaceKey={s}&title={s}&expand=body.storage,version,space",
            .{ space_key, encoded_title },
        );

        var endpoint_buffer: [512]u8 = undefined;
        const endpoint = try self.buildEndpoint(&endpoint_buffer, "/rest/api/content");
        return try self.client.makeRequest(.GET, endpoint, params);
    }

    /// Get child pages
    pub fn getPageChildren(self: *ConfluenceClient, parent_id: []const u8, limit: usize, include_body: bool) ![]u8 {
        var api_path_buffer: [256]u8 = undefined;
        const api_path = try std.fmt.bufPrint(&api_path_buffer, "/rest/api/content/{s}/child/page", .{parent_id});

        var endpoint_buffer: [512]u8 = undefined;
        const endpoint = try self.buildEndpoint(&endpoint_buffer, api_path);

        var params_buffer: [512]u8 = undefined;
        const expand = if (include_body) "body.storage,version,space" else "version,space";
        const params = try std.fmt.bufPrint(&params_buffer, "expand={s}&limit={d}", .{ expand, limit });

        return try self.client.makeRequest(.GET, endpoint, params);
    }

    /// Get page comments
    pub fn getComments(self: *ConfluenceClient, page_id: []const u8) ![]u8 {
        var api_path_buffer: [256]u8 = undefined;
        const api_path = try std.fmt.bufPrint(&api_path_buffer, "/rest/api/content/{s}/child/comment", .{page_id});

        var endpoint_buffer: [512]u8 = undefined;
        const endpoint = try self.buildEndpoint(&endpoint_buffer, api_path);

        const params = "expand=body.view,version";
        return try self.client.makeRequest(.GET, endpoint, params);
    }

    /// Get page labels
    pub fn getLabels(self: *ConfluenceClient, page_id: []const u8) ![]u8 {
        var api_path_buffer: [256]u8 = undefined;
        const api_path = try std.fmt.bufPrint(&api_path_buffer, "/rest/api/content/{s}/label", .{page_id});

        var endpoint_buffer: [512]u8 = undefined;
        const endpoint = try self.buildEndpoint(&endpoint_buffer, api_path);

        return try self.client.makeRequest(.GET, endpoint, null);
    }

    /// Get all spaces
    pub fn getSpaces(self: *ConfluenceClient, limit: usize) ![]u8 {
        var params_buffer: [256]u8 = undefined;
        const params = try std.fmt.bufPrint(&params_buffer, "limit={d}&expand=description.plain", .{limit});

        var endpoint_buffer: [512]u8 = undefined;
        const endpoint = try self.buildEndpoint(&endpoint_buffer, "/rest/api/space");
        return try self.client.makeRequest(.GET, endpoint, params);
    }

    /// Simple text search (wraps into CQL siteSearch)
    pub fn simpleSearch(self: *ConfluenceClient, query: []const u8, limit: usize) ![]u8 {
        // The search function will handle URL encoding
        var cql_buffer: [2048]u8 = undefined;
        const cql = try std.fmt.bufPrint(&cql_buffer, "type=page AND siteSearch ~ \"{s}\"", .{query});

        return try self.search(cql, limit);
    }

    /// Search pages by space
    pub fn searchInSpace(self: *ConfluenceClient, space_key: []const u8, query: []const u8, limit: usize) ![]u8 {
        // The search function will handle URL encoding
        var cql_buffer: [2048]u8 = undefined;
        const cql = try std.fmt.bufPrint(
            &cql_buffer,
            "type=page AND space={s} AND siteSearch ~ \"{s}\"",
            .{ space_key, query },
        );

        return try self.search(cql, limit);
    }

    /// Get space by key
    pub fn getSpace(self: *ConfluenceClient, space_key: []const u8) ![]u8 {
        var api_path_buffer: [256]u8 = undefined;
        const api_path = try std.fmt.bufPrint(&api_path_buffer, "/rest/api/space/{s}", .{space_key});

        var endpoint_buffer: [512]u8 = undefined;
        const endpoint = try self.buildEndpoint(&endpoint_buffer, api_path);

        const params = "expand=description.plain,homepage";
        return try self.client.makeRequest(.GET, endpoint, params);
    }
};
