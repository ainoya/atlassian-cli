const std = @import("std");

pub const OutputFormat = enum {
    text,
    json,
};

/// Extract the value of an HTML attribute from the inner content of a tag.
/// E.g., given `a href="https://example.com" class="link"` and "href",
/// returns "https://example.com" (a slice into tag_inner).
fn extractHtmlAttr(tag_inner: []const u8, attr_name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos + attr_name.len <= tag_inner.len) : (pos += 1) {
        if (!std.mem.startsWith(u8, tag_inner[pos..], attr_name)) continue;
        // Must be preceded by whitespace to avoid partial matches (e.g. "data-href")
        if (pos > 0 and !std.ascii.isWhitespace(tag_inner[pos - 1])) continue;
        var p = pos + attr_name.len;
        // Skip optional whitespace around =
        while (p < tag_inner.len and std.ascii.isWhitespace(tag_inner[p])) : (p += 1) {}
        if (p >= tag_inner.len or tag_inner[p] != '=') continue;
        p += 1;
        while (p < tag_inner.len and std.ascii.isWhitespace(tag_inner[p])) : (p += 1) {}
        if (p >= tag_inner.len) continue;
        const quote = tag_inner[p];
        if (quote != '"' and quote != '\'') continue;
        const val_start = p + 1;
        const val_end = std.mem.indexOfScalarPos(u8, tag_inner, val_start, quote) orelse continue;
        return tag_inner[val_start..val_end];
    }
    return null;
}

/// HTML tag stripper that preserves links and images.
/// <a href="url">text</a>  →  text (url)   [or just text if text == url]
/// <img src="url">          →  [image: url]
fn stripHtmlTags(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    var result = std.ArrayList(u8).initCapacity(allocator, html.len) catch return try allocator.dupe(u8, html);
    errdefer result.deinit(allocator);

    var i: usize = 0;
    var in_entity = false;
    var entity_buffer: [10]u8 = undefined;
    var entity_len: usize = 0;

    // Track current <a> href to append URL after link text if it differs
    var link_href: ?[]const u8 = null;
    var link_text_start: usize = 0;

    while (i < html.len) {
        const c = html[i];

        if (c == '<') {
            const close = std.mem.indexOfScalarPos(u8, html, i + 1, '>') orelse {
                i += 1;
                continue;
            };
            const tag_inner = html[i + 1 .. close];
            const trimmed = std.mem.trimLeft(u8, tag_inner, " \t\n\r");

            if (trimmed.len > 0 and trimmed[0] == 'a' and
                (trimmed.len == 1 or trimmed[1] == ' ' or trimmed[1] == '\t' or trimmed[1] == '\n'))
            {
                // Opening <a ...> tag - extract href
                link_href = extractHtmlAttr(tag_inner, "href");
                link_text_start = result.items.len;
            } else if (trimmed.len >= 2 and trimmed[0] == '/' and trimmed[1] == 'a' and
                (trimmed.len == 2 or trimmed[2] == ' ' or trimmed[2] == '\t'))
            {
                // Closing </a> tag - append URL if link text differs from href
                if (link_href) |href| {
                    const link_text = result.items[link_text_start..result.items.len];
                    const trimmed_text = std.mem.trim(u8, link_text, " \t\n\r");
                    if (!std.mem.eql(u8, trimmed_text, href)) {
                        try result.appendSlice(allocator, " (");
                        try result.appendSlice(allocator, href);
                        try result.appendSlice(allocator, ")");
                    }
                    link_href = null;
                }
            } else if (trimmed.len >= 3 and std.mem.startsWith(u8, trimmed, "img") and
                (trimmed.len == 3 or trimmed[3] == ' ' or trimmed[3] == '/' or trimmed[3] == '>'))
            {
                // <img> tag - show src URL
                if (extractHtmlAttr(tag_inner, "src")) |src| {
                    try result.appendSlice(allocator, "[image: ");
                    try result.appendSlice(allocator, src);
                    try result.appendSlice(allocator, "]");
                }
            } else {
                // Other tag - add space after for readability
                if (close + 1 < html.len and html[close + 1] != ' ' and html[close + 1] != '\n') {
                    try result.append(allocator, ' ');
                }
            }

            i = close + 1;
            continue;
        }

        // Entity handling
        if (c == '&') {
            in_entity = true;
            entity_len = 0;
        } else if (in_entity) {
            if (c == ';') {
                in_entity = false;
                const entity = entity_buffer[0..entity_len];
                if (std.mem.eql(u8, entity, "nbsp")) {
                    try result.append(allocator, ' ');
                } else if (std.mem.eql(u8, entity, "lt")) {
                    try result.append(allocator, '<');
                } else if (std.mem.eql(u8, entity, "gt")) {
                    try result.append(allocator, '>');
                } else if (std.mem.eql(u8, entity, "amp")) {
                    try result.append(allocator, '&');
                } else if (std.mem.eql(u8, entity, "quot")) {
                    try result.append(allocator, '"');
                } else {
                    // Unknown entity, skip
                }
            } else if (entity_len < entity_buffer.len) {
                entity_buffer[entity_len] = c;
                entity_len += 1;
            }
        } else {
            try result.append(allocator, c);
        }

        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

/// Clean up whitespace - replace multiple spaces/newlines with single space
fn cleanWhitespace(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, text.len);
    errdefer result.deinit(allocator);

    var last_was_space = false;
    for (text) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            if (!last_was_space) {
                try result.append(allocator, ' ');
                last_was_space = true;
            }
        } else {
            try result.append(allocator, c);
            last_was_space = false;
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Write plain text extracted from a Jira ADF (Atlassian Document Format) node.
/// Iterative DFS to avoid per-recursion allocations.
fn writeAdfText(writer: anytype, node: std.json.Value) !void {
    const max_stack = 64;
    var stack: [max_stack]struct { items: []const std.json.Value, idx: usize, is_block: bool } = undefined;
    var depth: usize = 0;

    // Seed with the root node's content array
    if (node != .object) return;
    const root_content = node.object.get("content") orelse return;
    if (root_content != .array) return;
    stack[0] = .{ .items = root_content.array.items, .idx = 0, .is_block = false };
    depth = 1;

    while (depth > 0) {
        const frame = &stack[depth - 1];
        if (frame.idx >= frame.items.len) {
            if (frame.is_block) {
                try writer.writeAll("\n");
            }
            depth -= 1;
            continue;
        }
        const child = frame.items[frame.idx];
        frame.idx += 1;

        if (child != .object) continue;
        const obj = child.object;

        // Emit text content
        if (obj.get("text")) |text_val| {
            if (text_val == .string) {
                try writer.writeAll(text_val.string);
                // Check for link marks and append URL if it differs from text
                if (obj.get("marks")) |marks_val| {
                    if (marks_val == .array) {
                        for (marks_val.array.items) |mark| {
                            if (mark != .object) continue;
                            const mt = if (mark.object.get("type")) |t| if (t == .string) t.string else null else null;
                            if (mt) |mark_type| {
                                if (std.mem.eql(u8, mark_type, "link")) {
                                    if (mark.object.get("attrs")) |attrs| {
                                        if (attrs == .object) {
                                            if (attrs.object.get("href")) |href| {
                                                if (href == .string and !std.mem.eql(u8, text_val.string, href.string)) {
                                                    try writer.writeAll(" (");
                                                    try writer.writeAll(href.string);
                                                    try writer.writeAll(")");
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Handle inlineCard (smart links / embedded URLs)
        {
            const nt = if (obj.get("type")) |t| if (t == .string) t.string else null else null;
            if (nt) |node_type| {
                if (std.mem.eql(u8, node_type, "inlineCard") or std.mem.eql(u8, node_type, "embedCard")) {
                    if (obj.get("attrs")) |attrs| {
                        if (attrs == .object) {
                            if (attrs.object.get("url")) |url| {
                                if (url == .string) {
                                    try writer.writeAll(url.string);
                                    try writer.writeAll("\n");
                                }
                            }
                        }
                    }
                } else if (std.mem.eql(u8, node_type, "mention")) {
                    if (obj.get("attrs")) |attrs| {
                        if (attrs == .object) {
                            if (attrs.object.get("text")) |text| {
                                if (text == .string) {
                                    try writer.writeAll(text.string);
                                }
                            }
                        }
                    }
                } else if (std.mem.eql(u8, node_type, "hardBreak")) {
                    try writer.writeAll("\n");
                } else if (std.mem.eql(u8, node_type, "media")) {
                    if (obj.get("attrs")) |attrs| {
                        if (attrs == .object) {
                            const mt = if (attrs.object.get("type")) |t| if (t == .string) t.string else null else null;
                            if (mt) |media_type| {
                                if (std.mem.eql(u8, media_type, "external")) {
                                    if (attrs.object.get("url")) |url| {
                                        if (url == .string) {
                                            try writer.writeAll("[image: ");
                                            try writer.writeAll(url.string);
                                            try writer.writeAll("]");
                                        } else {
                                            try writer.writeAll("[image]");
                                        }
                                    } else {
                                        try writer.writeAll("[image]");
                                    }
                                } else {
                                    const alt = if (attrs.object.get("alt")) |a| if (a == .string) a.string else null else null;
                                    if (alt) |alt_text| {
                                        try writer.writeAll("[image: ");
                                        try writer.writeAll(alt_text);
                                        try writer.writeAll("]");
                                    } else {
                                        try writer.writeAll("[image]");
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Push child's content array onto stack
        if (obj.get("content")) |content_val| {
            if (content_val == .array and depth < max_stack) {
                // Track whether this is a block-level node so we emit a newline after its children
                const is_block = if (obj.get("type")) |tv| if (tv == .string) blk: {
                    const t = tv.string;
                    break :blk (std.mem.eql(u8, t, "paragraph") or
                        std.mem.eql(u8, t, "heading") or
                        std.mem.eql(u8, t, "bulletList") or
                        std.mem.eql(u8, t, "orderedList") or
                        std.mem.eql(u8, t, "listItem") or
                        std.mem.eql(u8, t, "codeBlock") or
                        std.mem.eql(u8, t, "blockquote") or
                        std.mem.eql(u8, t, "rule"));
                } else false else false;
                stack[depth] = .{ .items = content_val.array.items, .idx = 0, .is_block = is_block };
                depth += 1;
                continue;
            }
        }

        // Newline after leaf block-level nodes (no content array)
        if (obj.get("type")) |type_val| {
            if (type_val == .string) {
                const t = type_val.string;
                if (std.mem.eql(u8, t, "rule")) {
                    try writer.writeAll("\n");
                }
            }
        }
    }
}

/// Format Confluence search results as readable text
pub fn formatConfluenceSearchResults(allocator: std.mem.Allocator, json_str: []const u8, show_full_content: bool) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const results = root.get("results") orelse return try allocator.dupe(u8, "No results found.\n");

    var output = try std.ArrayList(u8).initCapacity(allocator, 1024);
    errdefer output.deinit(allocator);
    const writer = output.writer(allocator);

    const results_array = results.array;
    try writer.print("Found {} result(s):\n\n", .{results_array.items.len});

    for (results_array.items, 0..) |result, i| {
        const obj = result.object;

        // Title
        const title = if (obj.get("title")) |t| t.string else "Untitled";
        try writer.print("[{}] {s}\n", .{ i + 1, title });

        // Space info
        if (obj.get("space")) |space| {
            const space_obj = space.object;
            const space_name = if (space_obj.get("name")) |n| n.string else "Unknown";
            const space_key = if (space_obj.get("key")) |k| k.string else "Unknown";
            try writer.print("    Space: {s} ({s})\n", .{ space_name, space_key });
        }

        // Version/Updated info
        if (obj.get("version")) |version| {
            const version_obj = version.object;
            if (version_obj.get("when")) |when| {
                try writer.print("    Updated: {s}\n", .{when.string});
            }
            if (version_obj.get("by")) |by| {
                const by_obj = by.object;
                if (by_obj.get("displayName")) |name| {
                    try writer.print("    Author: {s}\n", .{name.string});
                }
            }
        }

        // URL
        const id = if (obj.get("id")) |id_val| id_val.string else null;
        if (id) |page_id| {
            if (obj.get("space")) |space| {
                const space_obj = space.object;
                if (space_obj.get("key")) |key| {
                    try writer.print("    URL: https://.atlassian.net/wiki/spaces/{s}/pages/{s}\n", .{ key.string, page_id });
                }
            }
        }

        // Body content
        if (obj.get("body")) |body| {
            const body_obj = body.object;
            if (body_obj.get("storage")) |storage| {
                const storage_obj = storage.object;
                if (storage_obj.get("value")) |value| {
                    const html_content = value.string;
                    const stripped = try stripHtmlTags(allocator, html_content);
                    defer allocator.free(stripped);
                    const cleaned = try cleanWhitespace(allocator, stripped);
                    defer allocator.free(cleaned);

                    if (cleaned.len > 0) {
                        if (show_full_content) {
                            // Show full content (no limit)
                            try writer.writeAll("    Content:\n    ─────────────────────────────\n    ");
                            try writer.print("{s}\n", .{cleaned});
                        } else {
                            // Show preview (first 200 chars)
                            const preview_len = @min(cleaned.len, 200);
                            const preview = cleaned[0..preview_len];
                            try writer.writeAll("    Content: ");
                            try writer.print("{s}", .{preview});
                            if (cleaned.len > 200) {
                                try writer.print("... ({d} characters total, use --full-content for more)\n", .{cleaned.len});
                            } else {
                                try writer.writeAll("\n");
                            }
                        }
                    }
                }
            }
        }

        try writer.writeAll("\n");
    }

    return output.toOwnedSlice(allocator);
}

/// Format Jira search results as readable text
pub fn formatJiraSearchResults(allocator: std.mem.Allocator, json_str: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const issues = root.get("issues") orelse return try allocator.dupe(u8, "No issues found.\n");

    var output = try std.ArrayList(u8).initCapacity(allocator, 1024);
    errdefer output.deinit(allocator);
    const writer = output.writer(allocator);

    const issues_array = issues.array;
    const total: usize = if (root.get("total")) |t| @intCast(t.integer) else issues_array.items.len;
    try writer.print("Found {} issue(s):\n\n", .{total});

    for (issues_array.items, 0..) |issue, i| {
        const obj = issue.object;

        // Key and Summary
        const key = if (obj.get("key")) |k| k.string else "UNKNOWN";
        const fields = obj.get("fields") orelse continue;
        const fields_obj = fields.object;

        const summary = if (fields_obj.get("summary")) |s| s.string else "No summary";
        try writer.print("[{}] {s}: {s}\n", .{ i + 1, key, summary });

        // Status
        if (fields_obj.get("status")) |status| {
            const status_obj = status.object;
            if (status_obj.get("name")) |name| {
                try writer.print("    Status: {s}\n", .{name.string});
            }
        }

        // Assignee
        if (fields_obj.get("assignee")) |assignee| {
            if (assignee != .null) {
                const assignee_obj = assignee.object;
                if (assignee_obj.get("displayName")) |name| {
                    try writer.print("    Assignee: {s}\n", .{name.string});
                }
            } else {
                try writer.writeAll("    Assignee: Unassigned\n");
            }
        }

        // Priority
        if (fields_obj.get("priority")) |priority| {
            if (priority != .null) {
                const priority_obj = priority.object;
                if (priority_obj.get("name")) |name| {
                    try writer.print("    Priority: {s}\n", .{name.string});
                }
            }
        }

        // Created date
        if (fields_obj.get("created")) |created| {
            try writer.print("    Created: {s}\n", .{created.string});
        }

        try writer.writeAll("\n");
    }

    return output.toOwnedSlice(allocator);
}

/// Format Jira issue details as readable text
pub fn formatJiraIssue(allocator: std.mem.Allocator, json_str: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    var output = try std.ArrayList(u8).initCapacity(allocator, 1024);
    errdefer output.deinit(allocator);
    const writer = output.writer(allocator);

    // Key
    const key = if (root.get("key")) |k| k.string else "UNKNOWN";
    const fields = root.get("fields") orelse return try allocator.dupe(u8, "No fields found.\n");
    const fields_obj = fields.object;

    // Summary
    const summary = if (fields_obj.get("summary")) |s| s.string else "No summary";
    try writer.print("Issue: {s}\n", .{key});
    try writer.print("Summary: {s}\n", .{summary});
    try writer.writeAll("─────────────────────────────────────────\n\n");

    // Status
    if (fields_obj.get("status")) |status| {
        const status_obj = status.object;
        if (status_obj.get("name")) |name| {
            try writer.print("Status: {s}\n", .{name.string});
        }
    }

    // Issue Type
    if (fields_obj.get("issuetype")) |issuetype| {
        const type_obj = issuetype.object;
        if (type_obj.get("name")) |name| {
            try writer.print("Type: {s}\n", .{name.string});
        }
    }

    // Priority
    if (fields_obj.get("priority")) |priority| {
        if (priority != .null) {
            const priority_obj = priority.object;
            if (priority_obj.get("name")) |name| {
                try writer.print("Priority: {s}\n", .{name.string});
            }
        }
    }

    // Assignee
    if (fields_obj.get("assignee")) |assignee| {
        if (assignee != .null) {
            const assignee_obj = assignee.object;
            if (assignee_obj.get("displayName")) |name| {
                try writer.print("Assignee: {s}\n", .{name.string});
            }
        } else {
            try writer.writeAll("Assignee: Unassigned\n");
        }
    }

    // Reporter
    if (fields_obj.get("reporter")) |reporter| {
        if (reporter != .null) {
            const reporter_obj = reporter.object;
            if (reporter_obj.get("displayName")) |name| {
                try writer.print("Reporter: {s}\n", .{name.string});
            }
        }
    }

    // Labels
    if (fields_obj.get("labels")) |labels| {
        const labels_array = labels.array;
        if (labels_array.items.len > 0) {
            try writer.writeAll("Labels: ");
            for (labels_array.items, 0..) |label, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("{s}", .{label.string});
            }
            try writer.writeAll("\n");
        }
    }

    // Created/Updated
    if (fields_obj.get("created")) |created| {
        try writer.print("Created: {s}\n", .{created.string});
    }
    if (fields_obj.get("updated")) |updated| {
        try writer.print("Updated: {s}\n", .{updated.string});
    }

    // Description (can be a plain string or an ADF object in Jira Cloud)
    if (fields_obj.get("description")) |description| {
        if (description != .null) {
            try writer.writeAll("\nDescription:\n");
            try writer.writeAll("─────────────────────────────────────────\n");
            if (description == .string) {
                try writer.print("{s}\n", .{description.string});
            } else if (description == .object) {
                try writeAdfText(writer, description);
                try writer.writeAll("\n");
            }
        }
    }

    return output.toOwnedSlice(allocator);
}

/// Format Confluence page as readable text
/// base_url: Atlassian base URL (e.g. https://your-domain.atlassian.net)
pub fn formatConfluencePage(allocator: std.mem.Allocator, json_str: []const u8, base_url: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    var output = try std.ArrayList(u8).initCapacity(allocator, 1024);
    errdefer output.deinit(allocator);
    const writer = output.writer(allocator);

    // Title
    const title = if (root.get("title")) |t| t.string else "Untitled";
    try writer.print("Page: {s}\n", .{title});
    try writer.writeAll("─────────────────────────────────────────\n\n");

    // Space
    if (root.get("space")) |space| {
        const space_obj = space.object;
        const space_name = if (space_obj.get("name")) |n| n.string else "Unknown";
        const space_key = if (space_obj.get("key")) |k| k.string else "Unknown";
        try writer.print("Space: {s} ({s})\n", .{ space_name, space_key });
    }

    // Version info
    if (root.get("version")) |version| {
        const version_obj = version.object;
        if (version_obj.get("number")) |num| {
            try writer.print("Version: {}\n", .{num.integer});
        }
        if (version_obj.get("when")) |when| {
            try writer.print("Last Updated: {s}\n", .{when.string});
        }
        if (version_obj.get("by")) |by| {
            const by_obj = by.object;
            if (by_obj.get("displayName")) |name| {
                try writer.print("Last Modified By: {s}\n", .{name.string});
            }
        }
    }

    // URL
    const id = if (root.get("id")) |id_val| id_val.string else null;
    if (id) |page_id| {
        if (root.get("space")) |space| {
            const space_obj = space.object;
            if (space_obj.get("key")) |key| {
                // Dynamically generate Confluence page URL from base URL
                try writer.print("URL: {s}/wiki/spaces/{s}/pages/{s}\n", .{ base_url, key.string, page_id });
            }
        }
    }

    // Content
    if (root.get("body")) |body| {
        const body_obj = body.object;
        if (body_obj.get("storage")) |storage| {
            const storage_obj = storage.object;
            if (storage_obj.get("value")) |value| {
                try writer.writeAll("\nContent:\n");
                try writer.writeAll("─────────────────────────────────────────\n");

                const html_content = value.string;
                const stripped = try stripHtmlTags(allocator, html_content);
                defer allocator.free(stripped);
                const cleaned = try cleanWhitespace(allocator, stripped);
                defer allocator.free(cleaned);

                // Show full content for page details (no limit)
                try writer.print("{s}\n", .{cleaned});
            }
        }
    }

    return output.toOwnedSlice(allocator);
}

/// Format generic JSON list (spaces, projects, etc.) as readable text
pub fn formatGenericList(allocator: std.mem.Allocator, json_str: []const u8, item_name: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    var output = try std.ArrayList(u8).initCapacity(allocator, 1024);
    errdefer output.deinit(allocator);
    const writer = output.writer(allocator);

    // Try different array field names
    const root = parsed.value;
    const items = if (root == .object)
        root.object.get("results") orelse root.object.get("values") orelse root.object.get("items")
    else if (root == .array)
        root
    else
        null;

    if (items) |list| {
        const array = if (list == .array) list.array else return try allocator.dupe(u8, "No items found.\n");

        try writer.print("Found {} {s}(s):\n\n", .{ array.items.len, item_name });

        for (array.items, 0..) |item, i| {
            const obj = item.object;

            // Try common field names
            const name = if (obj.get("name")) |n| n.string else if (obj.get("title")) |t| t.string else if (obj.get("key")) |k| k.string else "Unknown";

            try writer.print("[{}] {s}\n", .{ i + 1, name });

            if (obj.get("key")) |key| {
                try writer.print("    Key: {s}\n", .{key.string});
            }

            if (obj.get("description")) |desc| {
                if (desc != .null) {
                    const desc_str = if (desc == .string) desc.string else if (desc == .object) blk: {
                        if (desc.object.get("plain")) |p| {
                            break :blk p.string;
                        }
                        break :blk null;
                    } else null;
                    if (desc_str) |d| {
                        const short_desc = if (d.len > 100) d[0..100] else d;
                        try writer.print("    Description: {s}...\n", .{short_desc});
                    }
                }
            }

            try writer.writeAll("\n");
        }

        return output.toOwnedSlice(allocator);
    }

    return try allocator.dupe(u8, "No items found.\n");
}
