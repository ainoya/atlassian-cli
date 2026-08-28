const std = @import("std");

pub const OutputFormat = enum {
    text,
    json,
};

/// Trim ASCII whitespace from both ends. std.mem.trimLeft was removed in Zig
/// 0.16, and this keeps the stripper independent of that churn.
fn trimAsciiWhitespace(text: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = text.len;
    while (start < end and std.ascii.isWhitespace(text[start])) : (start += 1) {}
    while (end > start and std.ascii.isWhitespace(text[end - 1])) : (end -= 1) {}
    return text[start..end];
}

/// Extract the value of an HTML attribute from the inner text of a tag.
/// Given `a href="https://example.com" class="link"` and "href", returns
/// "https://example.com" as a slice into `tag_inner`.
fn extractHtmlAttr(tag_inner: []const u8, attr_name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos + attr_name.len <= tag_inner.len) : (pos += 1) {
        if (!std.mem.startsWith(u8, tag_inner[pos..], attr_name)) continue;
        // Must be preceded by whitespace, so "data-href" does not match "href"
        if (pos > 0 and !std.ascii.isWhitespace(tag_inner[pos - 1])) continue;
        var p = pos + attr_name.len;
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

/// True when `trimmed` starts with `name` as a whole tag name, so that "a"
/// matches `<a href=...>` but not `<abbr>`.
fn tagNameIs(trimmed: []const u8, name: []const u8) bool {
    if (!std.mem.startsWith(u8, trimmed, name)) return false;
    if (trimmed.len == name.len) return true;
    const next = trimmed[name.len];
    return std.ascii.isWhitespace(next) or next == '/';
}

/// HTML tag stripper that keeps the information links carry.
///   <a href="url">text</a>  ->  text (url), or just text when they are equal
///   <img src="url">         ->  [image: url]
/// Other tags are dropped, and the basic named entities are decoded.
fn stripHtmlTags(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    var result = std.ArrayList(u8).initCapacity(allocator, html.len) catch return try allocator.dupe(u8, html);
    errdefer result.deinit(allocator);

    // href of the <a> currently open, and where its text began in `result`.
    var link_href: ?[]const u8 = null;
    var link_text_start: usize = 0;

    var i: usize = 0;
    while (i < html.len) {
        const c = html[i];

        if (c == '<') {
            const close = std.mem.indexOfScalarPos(u8, html, i + 1, '>') orelse {
                // Unterminated '<': treat it as text rather than losing the rest.
                try result.append(allocator, c);
                i += 1;
                continue;
            };
            const tag_inner = html[i + 1 .. close];
            const trimmed = trimAsciiWhitespace(tag_inner);

            if (tagNameIs(trimmed, "a")) {
                link_href = extractHtmlAttr(tag_inner, "href");
                link_text_start = result.items.len;
            } else if (tagNameIs(trimmed, "/a")) {
                if (link_href) |href| {
                    const link_text = result.items[link_text_start..];
                    const trimmed_text = trimAsciiWhitespace(link_text);
                    if (!std.mem.eql(u8, trimmed_text, href)) {
                        try result.appendSlice(allocator, " (");
                        try result.appendSlice(allocator, href);
                        try result.append(allocator, ')');
                    }
                    link_href = null;
                }
            } else if (tagNameIs(trimmed, "img")) {
                if (extractHtmlAttr(tag_inner, "src")) |src| {
                    try result.appendSlice(allocator, "[image: ");
                    try result.appendSlice(allocator, src);
                    try result.append(allocator, ']');
                }
            } else {
                // Any other tag: a space keeps words from running together.
                if (close + 1 < html.len and html[close + 1] != ' ' and html[close + 1] != '\n') {
                    try result.append(allocator, ' ');
                }
            }

            i = close + 1;
            continue;
        }

        if (c == '&') {
            // Decode a named entity, but only if it actually terminates: a bare
            // '&' in prose must survive rather than swallowing what follows.
            var end = i + 1;
            while (end < html.len and end - i <= 10 and (std.ascii.isAlphanumeric(html[end]) or html[end] == '#')) : (end += 1) {}
            if (end < html.len and html[end] == ';' and end > i + 1) {
                const entity = html[i + 1 .. end];
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
                } else if (std.mem.eql(u8, entity, "apos")) {
                    try result.append(allocator, '\'');
                }
                // Unknown entities are dropped, as before.
                i = end + 1;
                continue;
            }
            try result.append(allocator, c);
            i += 1;
            continue;
        }

        try result.append(allocator, c);
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

/// Render the plain text of a Jira ADF (Atlassian Document Format) node.
///
/// Iterative rather than recursive so a deeply nested (or hostile) document
/// cannot blow the stack; nodes deeper than `max_depth` are skipped.
fn writeAdfText(writer: *std.Io.Writer, node: std.json.Value) !void {
    const max_depth = 64;
    const Frame = struct { items: []const std.json.Value, idx: usize, is_block: bool };
    var stack: [max_depth]Frame = undefined;

    if (node != .object) return;
    const root_content = node.object.get("content") orelse return;
    if (root_content != .array) return;

    stack[0] = .{ .items = root_content.array.items, .idx = 0, .is_block = false };
    var depth: usize = 1;

    while (depth > 0) {
        const frame = &stack[depth - 1];
        if (frame.idx >= frame.items.len) {
            if (frame.is_block) try writer.writeAll("\n");
            depth -= 1;
            continue;
        }
        const child = frame.items[frame.idx];
        frame.idx += 1;

        if (child != .object) continue;
        const obj = child.object;
        const node_type = stringField(obj, "type");

        if (stringField(obj, "text")) |text| {
            try writer.writeAll(text);
            if (linkHref(obj)) |href| {
                if (!std.mem.eql(u8, text, href)) {
                    try writer.print(" ({s})", .{href});
                }
            }
        }

        if (node_type) |t| {
            if (std.mem.eql(u8, t, "inlineCard") or std.mem.eql(u8, t, "embedCard")) {
                if (attrString(obj, "url")) |url| try writer.print("{s}\n", .{url});
            } else if (std.mem.eql(u8, t, "mention")) {
                if (attrString(obj, "text")) |text| try writer.writeAll(text);
            } else if (std.mem.eql(u8, t, "hardBreak")) {
                try writer.writeAll("\n");
            } else if (std.mem.eql(u8, t, "media")) {
                try writeAdfMedia(writer, obj);
            }
        }

        if (obj.get("content")) |content| {
            if (content == .array and depth < max_depth) {
                stack[depth] = .{
                    .items = content.array.items,
                    .idx = 0,
                    .is_block = if (node_type) |t| isAdfBlock(t) else false,
                };
                depth += 1;
                continue;
            }
        }

        if (node_type) |t| {
            if (std.mem.eql(u8, t, "rule")) try writer.writeAll("\n");
        }
    }
}

fn isAdfBlock(node_type: []const u8) bool {
    const blocks = [_][]const u8{
        "paragraph",  "heading",   "bulletList", "orderedList",
        "listItem",   "codeBlock", "blockquote", "rule",
    };
    for (blocks) |block| {
        if (std.mem.eql(u8, node_type, block)) return true;
    }
    return false;
}

fn writeAdfMedia(writer: *std.Io.Writer, obj: std.json.ObjectMap) !void {
    const media_type = attrString(obj, "type") orelse {
        try writer.writeAll("[image]");
        return;
    };
    const label = if (std.mem.eql(u8, media_type, "external"))
        attrString(obj, "url")
    else
        attrString(obj, "alt");

    if (label) |text| {
        try writer.print("[image: {s}]", .{text});
    } else {
        try writer.writeAll("[image]");
    }
}

/// The value of `obj.field` when it is a string.
fn stringField(obj: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = obj.get(field) orelse return null;
    return if (value == .string) value.string else null;
}

/// The value of `obj.attrs.field` when it is a string.
fn attrString(obj: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const attrs = obj.get("attrs") orelse return null;
    if (attrs != .object) return null;
    return stringField(attrs.object, field);
}

/// The href of the first `link` mark on a text node, if it has one.
fn linkHref(obj: std.json.ObjectMap) ?[]const u8 {
    const marks = obj.get("marks") orelse return null;
    if (marks != .array) return null;
    for (marks.array.items) |mark| {
        if (mark != .object) continue;
        const mark_type = stringField(mark.object, "type") orelse continue;
        if (!std.mem.eql(u8, mark_type, "link")) continue;
        if (attrString(mark.object, "href")) |href| return href;
    }
    return null;
}

/// Format Confluence search results as readable text
pub fn formatConfluenceSearchResults(allocator: std.mem.Allocator, json_str: []const u8, show_full_content: bool) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const results = root.get("results") orelse return try allocator.dupe(u8, "No results found.\n");

    var output: std.Io.Writer.Allocating = try .initCapacity(allocator, 1024);
    errdefer output.deinit();
    const writer = &output.writer;

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

    return output.toOwnedSlice();
}

/// Format Jira search results as readable text
pub fn formatJiraSearchResults(allocator: std.mem.Allocator, json_str: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const issues = root.get("issues") orelse return try allocator.dupe(u8, "No issues found.\n");

    var output: std.Io.Writer.Allocating = try .initCapacity(allocator, 1024);
    errdefer output.deinit();
    const writer = &output.writer;

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

    return output.toOwnedSlice();
}

/// Format Jira issue details as readable text
pub fn formatJiraIssue(allocator: std.mem.Allocator, json_str: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    var output: std.Io.Writer.Allocating = try .initCapacity(allocator, 1024);
    errdefer output.deinit();
    const writer = &output.writer;

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

    // Description: a plain string on Jira Server/DC, an ADF document on Cloud
    if (fields_obj.get("description")) |description| {
        switch (description) {
            .null => {},
            .string => |text| {
                try writer.writeAll("\nDescription:\n");
                try writer.writeAll("─────────────────────────────────────────\n");
                try writer.print("{s}\n", .{text});
            },
            .object => {
                try writer.writeAll("\nDescription:\n");
                try writer.writeAll("─────────────────────────────────────────\n");
                try writeAdfText(writer, description);
                try writer.writeAll("\n");
            },
            else => {},
        }
    }

    return output.toOwnedSlice();
}

/// Format the comments of a Jira issue as readable text.
///
/// The comment body is an ADF document on Jira Cloud and a plain string on
/// Jira Server/DC, so both are handled.
pub fn formatJiraComments(allocator: std.mem.Allocator, json_str: []const u8, issue_key: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return try allocator.dupe(u8, "No comments found.\n");
    const comments = parsed.value.object.get("comments") orelse
        return try allocator.dupe(u8, "No comments found.\n");
    if (comments != .array) return try allocator.dupe(u8, "No comments found.\n");
    const items = comments.array.items;

    var output: std.Io.Writer.Allocating = try .initCapacity(allocator, 1024);
    errdefer output.deinit();
    const writer = &output.writer;

    try writer.print("Comments for {s} ({d} comment{s})\n", .{
        issue_key,
        items.len,
        if (items.len == 1) @as([]const u8, "") else "s",
    });
    try writer.writeAll("─────────────────────────────────────────\n");

    for (items) |comment| {
        if (comment != .object) continue;
        const obj = comment.object;

        if (stringField(obj, "created")) |created| {
            // "2026-08-27T12:34:56.789+0000" -> "2026-08-27 12:34"
            if (created.len >= 16) {
                try writer.print("{s} {s}", .{ created[0..10], created[11..16] });
            } else {
                try writer.writeAll(created);
            }
        }

        if (obj.get("author")) |author| {
            if (author == .object) {
                if (stringField(author.object, "displayName")) |name| {
                    try writer.print(" — {s}", .{name});
                }
            }
        }
        try writer.writeAll(":\n");

        if (obj.get("body")) |body| {
            switch (body) {
                .string => |text| try writer.writeAll(text),
                .object => try writeAdfText(writer, body),
                else => {},
            }
        }

        try writer.writeAll("\n");
    }

    return output.toOwnedSlice();
}

/// Format Confluence page as readable text
/// base_url: Atlassian base URL (e.g. https://your-domain.atlassian.net)
pub fn formatConfluencePage(allocator: std.mem.Allocator, json_str: []const u8, base_url: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    var output: std.Io.Writer.Allocating = try .initCapacity(allocator, 1024);
    errdefer output.deinit();
    const writer = &output.writer;

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

    return output.toOwnedSlice();
}

/// Format generic JSON list (spaces, projects, etc.) as readable text
pub fn formatGenericList(allocator: std.mem.Allocator, json_str: []const u8, item_name: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    var output: std.Io.Writer.Allocating = try .initCapacity(allocator, 1024);
    errdefer output.deinit();
    const writer = &output.writer;

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

        return output.toOwnedSlice();
    }

    return try allocator.dupe(u8, "No items found.\n");
}

test "formatJiraIssue renders an ADF description" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "key": "PROJ-1",
        \\  "fields": {
        \\    "summary": "Investigate the formatter",
        \\    "description": {
        \\      "type": "doc",
        \\      "version": 1,
        \\      "content": [
        \\        { "type": "paragraph", "content": [{ "type": "text", "text": "First line." }] },
        \\        { "type": "paragraph", "content": [
        \\          { "type": "text", "text": "See the docs",
        \\            "marks": [{ "type": "link", "attrs": { "href": "https://example.com/docs" } }] }
        \\        ]}
        \\      ]
        \\    }
        \\  }
        \\}
    ;

    const formatted = try formatJiraIssue(allocator, json);
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "Issue: PROJ-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "First line.") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "See the docs (https://example.com/docs)") != null);
}

test "formatJiraIssue still renders a plain string description" {
    const allocator = std.testing.allocator;
    const json =
        \\{ "key": "PROJ-2", "fields": { "summary": "Server", "description": "Plain text body" } }
    ;

    const formatted = try formatJiraIssue(allocator, json);
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "Plain text body") != null);
}

test "stripHtmlTags keeps link targets and image sources" {
    const allocator = std.testing.allocator;

    const with_link = try stripHtmlTags(allocator, "<p>See <a href=\"https://example.com\">the page</a>.</p>");
    defer allocator.free(with_link);
    try std.testing.expect(std.mem.indexOf(u8, with_link, "the page (https://example.com)") != null);

    // A link whose text is already the URL should not be repeated.
    const bare = try stripHtmlTags(allocator, "<a href=\"https://example.com\">https://example.com</a>");
    defer allocator.free(bare);
    try std.testing.expect(std.mem.indexOf(u8, bare, "(https://example.com)") == null);

    const image = try stripHtmlTags(allocator, "<img src=\"https://example.com/a.png\" />");
    defer allocator.free(image);
    try std.testing.expect(std.mem.indexOf(u8, image, "[image: https://example.com/a.png]") != null);
}

test "stripHtmlTags decodes entities without swallowing bare ampersands" {
    const allocator = std.testing.allocator;

    const decoded = try stripHtmlTags(allocator, "a &lt;b&gt; &amp; c");
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("a <b> & c", decoded);

    // A bare '&' must not consume the rest of the text.
    const bare = try stripHtmlTags(allocator, "Tom & Jerry");
    defer allocator.free(bare);
    try std.testing.expectEqualStrings("Tom & Jerry", bare);
}

test "formatJiraComments renders ADF bodies with author and date" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "comments": [
        \\    {
        \\      "created": "2026-08-27T12:34:56.789+0000",
        \\      "author": { "displayName": "Ada Lovelace" },
        \\      "body": {
        \\        "type": "doc",
        \\        "content": [
        \\          { "type": "paragraph", "content": [{ "type": "text", "text": "Looks good to me." }] }
        \\        ]
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    const formatted = try formatJiraComments(allocator, json, "PROJ-1");
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "Comments for PROJ-1 (1 comment)") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "2026-08-27 12:34") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "Ada Lovelace") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "Looks good to me.") != null);
}

test "formatJiraComments renders the plain string bodies Jira Server returns" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "comments": [
        \\    { "created": "2026-08-27T09:00:00.000+0000",
        \\      "author": { "displayName": "Grace Hopper" },
        \\      "body": "Plain text comment" },
        \\    { "created": "2026-08-27T10:00:00.000+0000",
        \\      "author": { "displayName": "Alan Turing" },
        \\      "body": "Second one" }
        \\  ]
        \\}
    ;

    const formatted = try formatJiraComments(allocator, json, "PROJ-2");
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "(2 comments)") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "Plain text comment") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "Second one") != null);
}

test "formatJiraComments tolerates responses without a comments array" {
    const allocator = std.testing.allocator;

    for ([_][]const u8{ "{}", "{\"comments\": null}", "{\"errorMessages\": [\"nope\"]}", "[]" }) |json| {
        const formatted = try formatJiraComments(allocator, json, "PROJ-3");
        defer allocator.free(formatted);
        try std.testing.expectEqualStrings("No comments found.\n", formatted);
    }
}
