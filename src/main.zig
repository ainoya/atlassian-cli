const std = @import("std");
const atlassian_cli = @import("atlassian_cli");
const AtlassianClient = atlassian_cli.AtlassianClient;
const JiraClient = atlassian_cli.JiraClient;
const ConfluenceClient = atlassian_cli.ConfluenceClient;
const formatter = atlassian_cli.formatter;

const OutputFormat = formatter.OutputFormat;
const config_mod = @import("config.zig");

const Service = enum {
    jira,
    confluence,
    config,
};

const JiraCommand = enum {
    issue,
    search,
    projects,
    @"project-issues",
    boards,
    sprints,
    @"sprint-issues",
    comments,
    user,
    help,
};

const ConfluenceCommand = enum {
    page,
    search,
    @"text-search",
    spaces,
    space,
    children,
    comments,
    labels,
    help,
};

fn printHelp() !void {
    const help =
        \\Atlassian CLI - Command line interface for Jira and Confluence
        \\
        \\Usage: atlassian-cli <service> <command> [options]
        \\
        \\Services:
        \\  jira          Jira operations
        \\  confluence    Confluence operations
        \\  config        Configuration management
        \\
        \\Environment Variables (required if not set in config):
        \\  ATLASSIAN_URL            Jira instance URL (e.g., https://your-domain.atlassian.net)
        \\  ATLASSIAN_USERNAME       Your email address
        \\  ATLASSIAN_API_TOKEN      Your API token
        \\  ATLASSIAN_CLOUD          Set to 'true' for Cloud, 'false' for Server/DC (default: true)
        \\  ATLASSIAN_JIRA_API_VERSION  Jira REST API version: 2, 3 or latest (default: 3 on Cloud, 2 on Server/DC)
        \\  CONFLUENCE_URL           Confluence base URL (falls back to ATLASSIAN_URL)
        \\  CONFLUENCE_USERNAME      Confluence username (falls back to ATLASSIAN_USERNAME)
        \\  CONFLUENCE_API_TOKEN     Confluence API token (falls back to ATLASSIAN_API_TOKEN)
        \\  CONFLUENCE_BASE_PATH     Confluence API base path (default: /wiki)
        \\
        \\Common Options:
        \\  --format=text            Output format: text (default) or json
        \\  --format=json            Raw JSON output
        \\  --full-content           Show full content (default shows preview only)
        \\  --expand-links[=N]       jira issue: also print the Confluence pages it links to (N=depth, max 3)
        \\
        \\Jira Commands:
        \\  issue <key>                        Get issue details (e.g., PROJECT-123)
        \\  search <jql> [--max=20]           Search issues using JQL
        \\  projects                           List all projects
        \\  project-issues <key> [--max=20]   Get issues in project
        \\  boards [--type=scrum]             List agile boards
        \\  sprints <board-id> [--state=active] List sprints
        \\  sprint-issues <sprint-id> [--max=50] Get issues in sprint
        \\  comments <issue-key>               Get issue comments
        \\  user                               Get current user info
        \\
        \\Confluence Commands:
        \\  page <id>                          Get page by ID
        \\  search <cql> [--limit=10]         Search using CQL
        \\  text-search <query> [--limit=10]  Simple text search
        \\  spaces [--limit=50]               List all spaces
        \\  space <key>                       Get space details
        \\  children <page-id> [--limit=25]   Get child pages
        \\  comments <page-id>                Get page comments
        \\  labels <page-id>                  Get page labels
        \\
        \\Examples:
        \\  # Jira (text format by default)
        \\  atlassian-cli jira issue PROJECT-123
        \\  atlassian-cli jira search "project=DEV AND status=Open" --max=50
        \\  atlassian-cli jira search "assignee=currentUser()" --format=json
        \\
        \\  # Confluence (text format by default)
        \\  atlassian-cli confluence page 123456
        \\  atlassian-cli confluence text-search "introduction" --limit=20
        \\  atlassian-cli confluence spaces --format=json
        \\
    ;
    std.debug.print("{s}\n", .{help});
}

fn printJiraHelp() !void {
    const help =
        \\Jira Commands:
        \\  issue <key>                        Get issue details
        \\  search <jql> [--max=20]           Search issues using JQL
        \\  projects                           List all projects
        \\  project-issues <key> [--max=20]   Get issues in project
        \\  boards [--type=scrum]             List agile boards
        \\  sprints <board-id> [--state=active] List sprints
        \\  sprint-issues <sprint-id> [--max=50] Get issues in sprint
        \\  comments <issue-key>               Get issue comments
        \\  user                               Get current user info
        \\
        \\JQL Examples:
        \\  "project=DEV AND status=Open"
        \\  "assignee=currentUser() ORDER BY created DESC"
        \\  "created >= -7d"
        \\
    ;
    std.debug.print("{s}\n", .{help});
}

/// Parse output format from args
fn parseOutputFormat(args: []const [:0]const u8) OutputFormat {
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--format=")) {
            const format_str = arg[9..];
            if (std.mem.eql(u8, format_str, "json")) {
                return .json;
            } else if (std.mem.eql(u8, format_str, "text")) {
                return .text;
            }
        }
    }
    return .text; // default
}

/// Check if --full-content flag is present
fn hasFullContentFlag(args: []const [:0]const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--full-content")) {
            return true;
        }
    }
    return false;
}

fn printConfluenceHelp() !void {
    const help =
        \\Confluence Commands:
        \\  page <id>                          Get page by ID
        \\  search <cql> [--limit=10]         Search using CQL
        \\  text-search <query> [--limit=10]  Simple text search (easier)
        \\  spaces [--limit=50]               List all spaces
        \\  space <key>                       Get space details
        \\  children <page-id> [--limit=25]   Get child pages
        \\  comments <page-id>                Get page comments
        \\  labels <page-id>                  Get page labels
        \\
        \\Text Search Examples:
        \\  confluence text-search "introduction"
        \\  confluence text-search "meeting notes"
        \\
        \\CQL Examples:
        \\  "type=page AND space=DEV"
        \\  "siteSearch ~ \"important concept\""
        \\  "created >= \"2024-01-01\""
        \\
    ;
    std.debug.print("{s}\n", .{help});
}

/// Everything the Confluence side of the CLI needs, resolved once in main().
/// Jira commands carry it too, so `--expand-links` can reach a Confluence that
/// lives on a different host under different credentials.
const ConfluenceContext = struct {
    client: *AtlassianClient,
    base_url: []const u8,
    base_path: []const u8,
};

/// Parse `--expand-links` / `--expand-links=N`. Null when absent. The depth is
/// clamped: each level fans out over every link on every page fetched, so an
/// unbounded value turns one command into a crawl of the whole space.
const max_expand_depth = 3;

fn parseExpandLinksDepth(args: []const [:0]const u8) ?usize {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--expand-links")) return 1;
        if (std.mem.startsWith(u8, arg, "--expand-links=")) {
            const raw = arg["--expand-links=".len..];
            const parsed = std.fmt.parseInt(usize, raw, 10) catch 1;
            return @max(1, @min(parsed, max_expand_depth));
        }
    }
    return null;
}

/// Total pages a single command may fetch while expanding, so a page that links
/// to hundreds of others cannot turn into hundreds of requests.
const max_expanded_pages = 20;

/// The page id of `url` when it points at a page on the configured Confluence
/// host, otherwise null.
///
/// The host check is the point: a Jira description can link anywhere, and a URL
/// merely containing "/pages/<digits>" is not reason enough to send credentials
/// at it.
fn confluencePageIdFor(confluence_base_url: []const u8, url: []const u8) ?[]const u8 {
    var host = confluence_base_url;
    while (host.len > 0 and host[host.len - 1] == '/') host = host[0 .. host.len - 1];
    if (host.len == 0) return null;
    if (!std.mem.startsWith(u8, url, host)) return null;

    // The prefix has to end at a path boundary, or "https://example.atlassian.net"
    // would also match "https://example.atlassian.net.evil.com/...".
    const rest = url[host.len..];
    if (rest.len > 0 and rest[0] != '/') return null;

    return formatter.extractConfluencePageId(rest);
}

/// Fetch a linked Confluence page, print it, and follow its own links while
/// depth and the page budget allow.
fn expandConfluenceLink(
    allocator: std.mem.Allocator,
    confluence: *ConfluenceClient,
    ctx: ConfluenceContext,
    url: []const u8,
    page_id: []const u8,
    remaining_depth: usize,
    visited: *std.ArrayList([]u8),
) void {
    if (remaining_depth == 0) return;
    if (visited.items.len >= max_expanded_pages) return;

    for (visited.items) |seen| {
        if (std.mem.eql(u8, seen, page_id)) return;
    }

    const owned_id = allocator.dupe(u8, page_id) catch return;
    visited.append(allocator, owned_id) catch {
        allocator.free(owned_id);
        return;
    };

    const page_response = confluence.getPage(page_id) catch |err| {
        std.debug.print("Warning: could not fetch Confluence page {s}: {t}\n", .{ page_id, err });
        return;
    };
    defer allocator.free(page_response);

    const page_formatted = formatter.formatConfluencePage(
        allocator,
        page_response,
        ctx.base_url,
        ctx.base_path,
    ) catch |err| {
        std.debug.print("Warning: could not format Confluence page {s}: {t}\n", .{ page_id, err });
        return;
    };
    defer allocator.free(page_formatted);

    std.debug.print("\n── Linked: {s} ──\n\n{s}", .{ url, page_formatted });

    if (remaining_depth <= 1) return;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, page_response, .{}) catch return;
    defer parsed.deinit();

    const storage = pageStorageBody(parsed.value) orelse return;
    const child_urls = formatter.extractHtmlUrls(allocator, storage) catch return;
    defer {
        for (child_urls) |u| allocator.free(u);
        allocator.free(child_urls);
    }

    for (child_urls) |child_url| {
        const child_id = confluencePageIdFor(ctx.base_url, child_url) orelse continue;
        expandConfluenceLink(allocator, confluence, ctx, child_url, child_id, remaining_depth - 1, visited);
    }
}

/// body.storage.value of a Confluence page response, when present.
fn pageStorageBody(page: std.json.Value) ?[]const u8 {
    if (page != .object) return null;
    const body = page.object.get("body") orelse return null;
    if (body != .object) return null;
    const storage = body.object.get("storage") orelse return null;
    if (storage != .object) return null;
    const value = storage.object.get("value") orelse return null;
    return if (value == .string) value.string else null;
}

/// Print the Confluence pages a Jira issue's description links to.
fn expandIssueLinks(
    allocator: std.mem.Allocator,
    ctx: ConfluenceContext,
    issue_response: []const u8,
    depth: usize,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, issue_response, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return;
    const fields = parsed.value.object.get("fields") orelse return;
    if (fields != .object) return;
    const description = fields.object.get("description") orelse return;
    if (description != .object) return;

    const urls = try formatter.extractAdfUrls(allocator, description);
    defer {
        for (urls) |url| allocator.free(url);
        allocator.free(urls);
    }

    var confluence = ConfluenceClient.init(ctx.client, allocator, ctx.base_path);

    var visited = try std.ArrayList([]u8).initCapacity(allocator, 16);
    defer {
        for (visited.items) |id| allocator.free(id);
        visited.deinit(allocator);
    }

    for (urls) |url| {
        const page_id = confluencePageIdFor(ctx.base_url, url) orelse continue;
        expandConfluenceLink(allocator, &confluence, ctx, url, page_id, depth, &visited);
    }
}

fn handleJiraCommand(allocator: std.mem.Allocator, client: *AtlassianClient, confluence: ConfluenceContext, args: []const [:0]const u8) !void {
    if (args.len < 1) {
        try printJiraHelp();
        return;
    }

    const command = std.meta.stringToEnum(JiraCommand, args[0]) orelse {
        std.debug.print("Unknown Jira command: {s}\n", .{args[0]});
        try printJiraHelp();
        return;
    };

    var jira = JiraClient.init(client, allocator);
    const output_format = parseOutputFormat(args);

    switch (command) {
        .help => try printJiraHelp(),
        .issue => {
            if (args.len < 2) {
                std.debug.print("Usage: jira issue <issue-key> [--format=text|json] [--expand-links[=N]]\n", .{});
                return;
            }
            // JSON consumers get the comments inline, saving a second call.
            // The text view keeps its existing shape and uses `jira comments`.
            const json_fields = "summary,description,status,assignee,reporter," ++
                "labels,priority,created,updated,issuetype,comment";
            const fields: ?[]const u8 = if (output_format == .json) json_fields else null;
            const response = try jira.getIssue(args[1], fields);
            defer allocator.free(response);

            if (output_format == .text) {
                const formatted = try formatter.formatJiraIssue(allocator, response);
                defer allocator.free(formatted);
                std.debug.print("{s}", .{formatted});

                if (parseExpandLinksDepth(args)) |depth| {
                    try expandIssueLinks(allocator, confluence, response, depth);
                }
            } else {
                std.debug.print("{s}\n", .{response});
            }
        },
        .search => {
            if (args.len < 2) {
                std.debug.print("Usage: jira search <jql> [--max=20] [--format=text|json]\n", .{});
                return;
            }
            var max_results: usize = 20;
            if (args.len > 2 and std.mem.startsWith(u8, args[2], "--max=")) {
                max_results = std.fmt.parseInt(usize, args[2][6..], 10) catch 20;
            }
            const response = try jira.search(args[1], null, max_results);
            defer allocator.free(response);

            if (output_format == .text) {
                const formatted = try formatter.formatJiraSearchResults(allocator, response);
                defer allocator.free(formatted);
                std.debug.print("{s}", .{formatted});
            } else {
                std.debug.print("{s}\n", .{response});
            }
        },
        .projects => {
            const response = try jira.getProjects();
            defer allocator.free(response);

            if (output_format == .text) {
                const formatted = try formatter.formatGenericList(allocator, response, "project");
                defer allocator.free(formatted);
                std.debug.print("{s}", .{formatted});
            } else {
                std.debug.print("{s}\n", .{response});
            }
        },
        .@"project-issues" => {
            if (args.len < 2) {
                std.debug.print("Usage: jira project-issues <project-key> [--max=20] [--format=text|json]\n", .{});
                return;
            }
            var max_results: usize = 20;
            if (args.len > 2 and std.mem.startsWith(u8, args[2], "--max=")) {
                max_results = std.fmt.parseInt(usize, args[2][6..], 10) catch 20;
            }
            const response = try jira.getProjectIssues(args[1], max_results);
            defer allocator.free(response);

            if (output_format == .text) {
                const formatted = try formatter.formatJiraSearchResults(allocator, response);
                defer allocator.free(formatted);
                std.debug.print("{s}", .{formatted});
            } else {
                std.debug.print("{s}\n", .{response});
            }
        },
        .boards => {
            var board_type: ?[]const u8 = null;
            var max_results: usize = 50;
            for (args[1..]) |arg| {
                if (std.mem.startsWith(u8, arg, "--type=")) {
                    board_type = arg[7..];
                } else if (std.mem.startsWith(u8, arg, "--max=")) {
                    max_results = std.fmt.parseInt(usize, arg[6..], 10) catch 50;
                }
            }
            const response = try jira.getBoards(board_type, max_results);
            defer allocator.free(response);
            std.debug.print("{s}\n", .{response});
        },
        .sprints => {
            if (args.len < 2) {
                std.debug.print("Usage: jira sprints <board-id> [--state=active]\n", .{});
                return;
            }
            var state: ?[]const u8 = null;
            if (args.len > 2 and std.mem.startsWith(u8, args[2], "--state=")) {
                state = args[2][8..];
            }
            const response = try jira.getSprints(args[1], state);
            defer allocator.free(response);
            std.debug.print("{s}\n", .{response});
        },
        .@"sprint-issues" => {
            if (args.len < 2) {
                std.debug.print("Usage: jira sprint-issues <sprint-id> [--max=50]\n", .{});
                return;
            }
            var max_results: usize = 50;
            if (args.len > 2 and std.mem.startsWith(u8, args[2], "--max=")) {
                max_results = std.fmt.parseInt(usize, args[2][6..], 10) catch 50;
            }
            const response = try jira.getSprintIssues(args[1], max_results);
            defer allocator.free(response);
            std.debug.print("{s}\n", .{response});
        },
        .comments => {
            if (args.len < 2) {
                std.debug.print("Usage: jira comments <issue-key> [--format=text|json]\n", .{});
                return;
            }
            const response = try jira.getComments(args[1]);
            defer allocator.free(response);

            if (output_format == .text) {
                const formatted = try formatter.formatJiraComments(allocator, response, args[1]);
                defer allocator.free(formatted);
                std.debug.print("{s}", .{formatted});
            } else {
                std.debug.print("{s}\n", .{response});
            }
        },
        .user => {
            const response = try jira.getCurrentUser();
            defer allocator.free(response);
            std.debug.print("{s}\n", .{response});
        },
    }
}

/// Modify Confluence command handler to pass base URL
fn handleConfluenceCommand(allocator: std.mem.Allocator, ctx: ConfluenceContext, args: []const [:0]const u8) !void {
    const base_url = ctx.base_url;
    const confluence_base_path = ctx.base_path;
    if (args.len < 1) {
        try printConfluenceHelp();
        return;
    }

    const command = std.meta.stringToEnum(ConfluenceCommand, args[0]) orelse {
        std.debug.print("Unknown Confluence command: {s}\n", .{args[0]});
        try printConfluenceHelp();
        return;
    };

    var confluence = ConfluenceClient.init(ctx.client, allocator, confluence_base_path);

    const output_format = parseOutputFormat(args);
    const show_full_content = hasFullContentFlag(args);

    switch (command) {
        .help => try printConfluenceHelp(),
        .page => {
            if (args.len < 2) {
                std.debug.print("Usage: confluence page <page-id> [--format=text|json]\n", .{});
                return;
            }
            const response = try confluence.getPage(args[1]);
            defer allocator.free(response);

            if (output_format == .text) {
                // Pass base URL to formatter to dynamically generate page URL
                const formatted = try formatter.formatConfluencePage(allocator, response, base_url, confluence_base_path);
                defer allocator.free(formatted);
                std.debug.print("{s}", .{formatted});
            } else {
                std.debug.print("{s}\n", .{response});
            }
        },
        .search => {
            if (args.len < 2) {
                std.debug.print("Usage: confluence search <cql> [--limit=10] [--format=text|json] [--full-content]\n", .{});
                return;
            }
            var limit: usize = 10;
            if (args.len > 2 and std.mem.startsWith(u8, args[2], "--limit=")) {
                limit = std.fmt.parseInt(usize, args[2][8..], 10) catch 10;
            }
            const response = try confluence.search(args[1], limit);
            defer allocator.free(response);

            if (output_format == .text) {
                const formatted = try formatter.formatConfluenceSearchResults(allocator, response, base_url, confluence_base_path, show_full_content);
                defer allocator.free(formatted);
                std.debug.print("{s}", .{formatted});
            } else {
                std.debug.print("{s}\n", .{response});
            }
        },
        .@"text-search" => {
            if (args.len < 2) {
                std.debug.print("Usage: confluence text-search <query> [--limit=10] [--format=text|json] [--full-content]\n", .{});
                return;
            }
            var limit: usize = 10;
            if (args.len > 2 and std.mem.startsWith(u8, args[2], "--limit=")) {
                limit = std.fmt.parseInt(usize, args[2][8..], 10) catch 10;
            }
            const response = try confluence.simpleSearch(args[1], limit);
            defer allocator.free(response);

            if (output_format == .text) {
                const formatted = try formatter.formatConfluenceSearchResults(allocator, response, base_url, confluence_base_path, show_full_content);
                defer allocator.free(formatted);
                std.debug.print("{s}", .{formatted});
            } else {
                std.debug.print("{s}\n", .{response});
            }
        },
        .spaces => {
            var limit: usize = 50;
            if (args.len > 1 and std.mem.startsWith(u8, args[1], "--limit=")) {
                limit = std.fmt.parseInt(usize, args[1][8..], 10) catch 50;
            }
            const response = try confluence.getSpaces(limit);
            defer allocator.free(response);

            if (output_format == .text) {
                const formatted = try formatter.formatGenericList(allocator, response, "space");
                defer allocator.free(formatted);
                std.debug.print("{s}", .{formatted});
            } else {
                std.debug.print("{s}\n", .{response});
            }
        },
        .space => {
            if (args.len < 2) {
                std.debug.print("Usage: confluence space <space-key> [--format=text|json]\n", .{});
                return;
            }
            const response = try confluence.getSpace(args[1]);
            defer allocator.free(response);

            if (output_format == .text) {
                const formatted = try formatter.formatGenericList(allocator, response, "space");
                defer allocator.free(formatted);
                std.debug.print("{s}", .{formatted});
            } else {
                std.debug.print("{s}\n", .{response});
            }
        },
        .children => {
            if (args.len < 2) {
                std.debug.print("Usage: confluence children <page-id> [--limit=25] [--format=text|json] [--full-content]\n", .{});
                return;
            }
            var limit: usize = 25;
            if (args.len > 2 and std.mem.startsWith(u8, args[2], "--limit=")) {
                limit = std.fmt.parseInt(usize, args[2][8..], 10) catch 25;
            }
            const response = try confluence.getPageChildren(args[1], limit, false);
            defer allocator.free(response);

            if (output_format == .text) {
                const formatted = try formatter.formatConfluenceSearchResults(allocator, response, base_url, confluence_base_path, show_full_content);
                defer allocator.free(formatted);
                std.debug.print("{s}", .{formatted});
            } else {
                std.debug.print("{s}\n", .{response});
            }
        },
        .comments => {
            if (args.len < 2) {
                std.debug.print("Usage: confluence comments <page-id> [--format=text|json]\n", .{});
                return;
            }
            const response = try confluence.getComments(args[1]);
            defer allocator.free(response);

            if (output_format == .text) {
                const formatted = try formatter.formatGenericList(allocator, response, "comment");
                defer allocator.free(formatted);
                std.debug.print("{s}", .{formatted});
            } else {
                std.debug.print("{s}\n", .{response});
            }
        },
        .labels => {
            if (args.len < 2) {
                std.debug.print("Usage: confluence labels <page-id> [--format=text|json]\n", .{});
                return;
            }
            const response = try confluence.getLabels(args[1]);
            defer allocator.free(response);

            if (output_format == .text) {
                const formatted = try formatter.formatGenericList(allocator, response, "label");
                defer allocator.free(formatted);
                std.debug.print("{s}", .{formatted});
            } else {
                std.debug.print("{s}\n", .{response});
            }
        },
    }
}

/// The environment value when it is set and non-empty, otherwise the fallback.
fn nonEmptyOr(value: ?[]const u8, fallback: []const u8) []const u8 {
    if (value) |v| {
        if (v.len > 0) return v;
    }
    return fallback;
}

/// Jira Cloud speaks v3, Server/DC speaks v2. ATLASSIAN_JIRA_API_VERSION
/// overrides that, but only with a version this CLI knows how to address —
/// anything else would be pasted straight into the request path.
fn resolveJiraApiVersion(override: ?[]const u8, is_cloud: bool) []const u8 {
    const default: []const u8 = if (is_cloud) "3" else "2";
    const requested = override orelse return default;
    if (requested.len == 0) return default;

    for ([_][]const u8{ "2", "3", "latest" }) |supported| {
        if (std.mem.eql(u8, requested, supported)) return supported;
    }

    std.debug.print(
        "Warning: ignoring ATLASSIAN_JIRA_API_VERSION={s}; expected 2, 3 or latest. Using {s}.\n",
        .{ requested, default },
    );
    return default;
}

pub fn main(init: std.process.Init) !void {
    // Zig 0.16 hands the program its allocators, Io implementation and
    // process environment; there is no need to construct them here.
    const allocator = init.gpa;
    const io = init.io;
    const environ = init.minimal.environ;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        try printHelp();
        return;
    }

    const service_str = args[1];
    const service = std.meta.stringToEnum(Service, service_str) orelse {
        std.debug.print("Unknown service: {s}\n", .{service_str});
        try printHelp();
        return;
    };

    // Check for help command before requiring environment variables
    if (args.len >= 3 and std.mem.eql(u8, args[2], "help")) {
        switch (service) {
            .jira => try printJiraHelp(),
            .confluence => try printConfluenceHelp(),
            .config => try printHelp(),
        }
        return;
    }

    // Load config
    var config = config_mod.Config.init(allocator, io, environ);
    defer config.deinit();
    try config.load();

    // Config command specific handling (doesn't need auth vars)
    if (service == .config) {
        if (args.len < 4) { // service + subcommand + key = 4 min? No, atlassian-cli config set key val -> 4 args
            // args[0] = exe, args[1] = config, args[2] = set/get
            if (args.len < 3) {
                std.debug.print("Usage: {s} config <set|get> <key> [value]\n", .{args[0]});
                return;
            }
        }

        const subcommand = args[2];
        if (std.mem.eql(u8, subcommand, "set")) {
            if (args.len < 5) {
                std.debug.print("Usage: {s} config set <key> <value>\n", .{args[0]});
                return;
            }
            try config.set(args[3], args[4]);
            try config.save();
            std.debug.print("✅ Updated {s}\n", .{args[3]});
        } else if (std.mem.eql(u8, subcommand, "get")) {
            if (args.len < 4) {
                std.debug.print("Usage: {s} config get <key>\n", .{args[0]});
                return;
            }
            if (config.get(args[3])) |val| {
                std.debug.print("{s}\n", .{val});
            } else {
                std.debug.print("(null)\n", .{});
            }
        } else {
            std.debug.print("Unknown config subcommand: {s}\n", .{subcommand});
        }
        return;
    }

    // Get environment variables or config
    // Helper to get optional env var
    const env_url = environ.getAlloc(allocator, "ATLASSIAN_URL") catch alias: {
        break :alias null;
    };
    defer if (env_url) |e| allocator.free(e);

    const base_url = try config_mod.resolve(allocator, env_url, config.atlassian_url, false) orelse {
        std.debug.print("Error: ATLASSIAN_URL environment variable not set and no config found.\n", .{});
        std.debug.print("Example: export ATLASSIAN_URL=https://your-domain.atlassian.net\n", .{});
        return error.ConfigurationMissing;
    };
    defer allocator.free(base_url);

    const env_username = environ.getAlloc(allocator, "ATLASSIAN_USERNAME") catch null;
    defer if (env_username) |e| allocator.free(e);

    const username = try config_mod.resolve(allocator, env_username, config.atlassian_username, false) orelse {
        std.debug.print("Error: ATLASSIAN_USERNAME environment variable not set and no config found.\n", .{});
        return error.ConfigurationMissing;
    };
    defer allocator.free(username);

    const env_token = environ.getAlloc(allocator, "ATLASSIAN_API_TOKEN") catch null;
    defer if (env_token) |e| allocator.free(e);

    const api_token = try config_mod.resolve(allocator, env_token, config.atlassian_api_token, false) orelse {
        std.debug.print("Error: ATLASSIAN_API_TOKEN environment variable not set and no config found.\n", .{});
        return error.ConfigurationMissing;
    };
    defer allocator.free(api_token);

    const is_cloud_str = environ.getAlloc(allocator, "ATLASSIAN_CLOUD") catch "true";
    defer if (!std.mem.eql(u8, is_cloud_str, "true")) allocator.free(is_cloud_str);
    const is_cloud = std.mem.eql(u8, is_cloud_str, "true");

    // Confluence may live on a different host, under different credentials,
    // from Jira. Each falls back to the shared ATLASSIAN_* value.
    const env_confluence_url = environ.getAlloc(allocator, "CONFLUENCE_URL") catch null;
    defer if (env_confluence_url) |e| allocator.free(e);
    const env_confluence_username = environ.getAlloc(allocator, "CONFLUENCE_USERNAME") catch null;
    defer if (env_confluence_username) |e| allocator.free(e);
    const env_confluence_token = environ.getAlloc(allocator, "CONFLUENCE_API_TOKEN") catch null;
    defer if (env_confluence_token) |e| allocator.free(e);

    const confluence_url = nonEmptyOr(env_confluence_url, base_url);
    const confluence_username = nonEmptyOr(env_confluence_username, username);
    const confluence_api_token = nonEmptyOr(env_confluence_token, api_token);

    const env_api_version = environ.getAlloc(allocator, "ATLASSIAN_JIRA_API_VERSION") catch null;
    defer if (env_api_version) |e| allocator.free(e);
    const jira_api_version = resolveJiraApiVersion(env_api_version, is_cloud);

    // Initialize client
    const env_base_path = environ.getAlloc(allocator, "CONFLUENCE_BASE_PATH") catch null;
    defer if (env_base_path) |e| allocator.free(e);
    // An empty CONFLUENCE_BASE_PATH is meaningful: a Server/DC instance served
    // at the root. Only an unset variable falls back to the Cloud default.
    const confluence_base_path = env_base_path orelse "/wiki";

    var jira_client = AtlassianClient.init(
        allocator,
        io,
        base_url,
        username,
        api_token,
        jira_api_version,
        is_cloud,
    );
    defer jira_client.deinit();

    // Built for both services: Jira commands need it for --expand-links, and
    // it addresses the Confluence host and credentials either way.
    var confluence_client = AtlassianClient.init(
        allocator,
        io,
        confluence_url,
        confluence_username,
        confluence_api_token,
        jira_api_version,
        is_cloud,
    );
    defer confluence_client.deinit();

    const confluence_ctx: ConfluenceContext = .{
        .client = &confluence_client,
        .base_url = confluence_url,
        .base_path = confluence_base_path,
    };

    switch (service) {
        .jira => try handleJiraCommand(allocator, &jira_client, confluence_ctx, args[2..]),
        .confluence => try handleConfluenceCommand(allocator, confluence_ctx, args[2..]),
        .config => {}, // Handled above
    }
}

test "resolveJiraApiVersion defaults per deployment and validates overrides" {
    // Cloud speaks v3, Server/DC speaks v2, when nothing is set.
    try std.testing.expectEqualStrings("3", resolveJiraApiVersion(null, true));
    try std.testing.expectEqualStrings("2", resolveJiraApiVersion(null, false));

    // Supported overrides win.
    try std.testing.expectEqualStrings("2", resolveJiraApiVersion("2", true));
    try std.testing.expectEqualStrings("latest", resolveJiraApiVersion("latest", false));

    // Anything else falls back rather than reaching the request path.
    try std.testing.expectEqualStrings("3", resolveJiraApiVersion("4", true));
    try std.testing.expectEqualStrings("2", resolveJiraApiVersion("../../admin", false));
    try std.testing.expectEqualStrings("3", resolveJiraApiVersion("", true));
}

test "nonEmptyOr falls back for unset and empty values" {
    try std.testing.expectEqualStrings("fallback", nonEmptyOr(null, "fallback"));
    try std.testing.expectEqualStrings("fallback", nonEmptyOr("", "fallback"));
    try std.testing.expectEqualStrings("set", nonEmptyOr("set", "fallback"));
}

test "parseExpandLinksDepth clamps the requested depth" {
    const bare = [_][:0]const u8{ "issue", "PROJ-1", "--expand-links" };
    const two = [_][:0]const u8{ "issue", "PROJ-1", "--expand-links=2" };
    const huge = [_][:0]const u8{ "issue", "PROJ-1", "--expand-links=99" };
    const zero = [_][:0]const u8{ "issue", "PROJ-1", "--expand-links=0" };
    const junk = [_][:0]const u8{ "issue", "PROJ-1", "--expand-links=deep" };
    const absent = [_][:0]const u8{ "issue", "PROJ-1" };

    try std.testing.expectEqual(@as(?usize, 1), parseExpandLinksDepth(&bare));
    try std.testing.expectEqual(@as(?usize, 2), parseExpandLinksDepth(&two));
    try std.testing.expectEqual(@as(?usize, max_expand_depth), parseExpandLinksDepth(&huge));
    try std.testing.expectEqual(@as(?usize, 1), parseExpandLinksDepth(&zero));
    try std.testing.expectEqual(@as(?usize, 1), parseExpandLinksDepth(&junk));
    try std.testing.expectEqual(@as(?usize, null), parseExpandLinksDepth(&absent));
}

test "confluencePageIdFor only expands links on the configured host" {
    const host = "https://example.atlassian.net";

    try std.testing.expectEqualStrings(
        "12345",
        confluencePageIdFor(host, "https://example.atlassian.net/wiki/spaces/OPS/pages/12345/Runbook").?,
    );

    // A trailing slash in the configured URL must not defeat the match.
    try std.testing.expectEqualStrings(
        "12345",
        confluencePageIdFor("https://example.atlassian.net/", "https://example.atlassian.net/wiki/spaces/OPS/pages/12345").?,
    );

    // Somewhere else entirely, even though it looks like a Confluence URL.
    try std.testing.expect(confluencePageIdFor(host, "https://evil.example.com/wiki/spaces/X/pages/12345") == null);

    // A lookalike host that merely starts with the configured one is not it.
    try std.testing.expect(confluencePageIdFor(host, "https://example.atlassian.net.evil.com/wiki/spaces/X/pages/12345") == null);

    // On the right host but not a page link.
    try std.testing.expect(confluencePageIdFor(host, "https://example.atlassian.net/browse/PROJ-1") == null);
    try std.testing.expect(confluencePageIdFor(host, "https://example.atlassian.net/wiki/spaces/OPS/pages/") == null);
}
