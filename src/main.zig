const std = @import("std");
const atlassian_cli = @import("atlassian_cli");
const AtlassianClient = atlassian_cli.AtlassianClient;
const JiraClient = atlassian_cli.JiraClient;
const ConfluenceClient = atlassian_cli.ConfluenceClient;
const formatter = atlassian_cli.formatter;
const OutputFormat = formatter.OutputFormat;

const Service = enum {
    jira,
    confluence,
};

const JiraCommand = enum {
    issue,
    search,
    projects,
    @"project-issues",
    boards,
    sprints,
    @"sprint-issues",
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
        \\
        \\Environment Variables (required):
        \\  ATLASSIAN_URL            Your Atlassian instance URL (e.g., https://your-domain.atlassian.net)
        \\  ATLASSIAN_USERNAME       Your email address
        \\  ATLASSIAN_API_TOKEN      Your API token
        \\  ATLASSIAN_CLOUD          Set to 'true' for Cloud, 'false' for Server/DC (default: true)
        \\  CONFLUENCE_BASE_PATH     Confluence API base path (default: /wiki)
        \\
        \\Common Options:
        \\  --format=text            Output format: text (default) or json
        \\  --format=json            Raw JSON output
        \\  --full-content           Show full content (default shows preview only)
        \\
        \\Jira Commands:
        \\  issue <key>                        Get issue details (e.g., PROJECT-123)
        \\  search <jql> [--max=20]           Search issues using JQL
        \\  projects                           List all projects
        \\  project-issues <key> [--max=20]   Get issues in project
        \\  boards [--type=scrum]             List agile boards
        \\  sprints <board-id> [--state=active] List sprints
        \\  sprint-issues <sprint-id> [--max=50] Get issues in sprint
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

fn handleJiraCommand(allocator: std.mem.Allocator, client: *AtlassianClient, args: []const [:0]const u8) !void {
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
                std.debug.print("Usage: jira issue <issue-key> [--format=text|json]\n", .{});
                return;
            }
            const response = try jira.getIssue(args[1], null);
            defer allocator.free(response);

            if (output_format == .text) {
                const formatted = try formatter.formatJiraIssue(allocator, response);
                defer allocator.free(formatted);
                std.debug.print("{s}", .{formatted});
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
        .user => {
            const response = try jira.getCurrentUser();
            defer allocator.free(response);
            std.debug.print("{s}\n", .{response});
        },
    }
}

/// ConfluenceコマンドのハンドラーにベースURLを渡すように修正
fn handleConfluenceCommand(allocator: std.mem.Allocator, client: *AtlassianClient, args: []const [:0]const u8, base_url: []const u8) !void {
    if (args.len < 1) {
        try printConfluenceHelp();
        return;
    }

    const command = std.meta.stringToEnum(ConfluenceCommand, args[0]) orelse {
        std.debug.print("Unknown Confluence command: {s}\n", .{args[0]});
        try printConfluenceHelp();
        return;
    };

    // Get Confluence base path (default: /wiki for Confluence Cloud)
    const confluence_base_path = std.process.getEnvVarOwned(allocator, "CONFLUENCE_BASE_PATH") catch "/wiki";
    defer if (!std.mem.eql(u8, confluence_base_path, "/wiki")) allocator.free(confluence_base_path);

    var confluence = ConfluenceClient.init(client, allocator, confluence_base_path);

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
                // ベースURLをフォーマッターに渡してページURLを動的に生成
                const formatted = try formatter.formatConfluencePage(allocator, response, base_url);
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
                const formatted = try formatter.formatConfluenceSearchResults(allocator, response, show_full_content);
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
                const formatted = try formatter.formatConfluenceSearchResults(allocator, response, show_full_content);
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
                const formatted = try formatter.formatConfluenceSearchResults(allocator, response, show_full_content);
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

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
        }
        return;
    }

    // Get environment variables
    const base_url = std.process.getEnvVarOwned(allocator, "ATLASSIAN_URL") catch |err| {
        std.debug.print("Error: ATLASSIAN_URL environment variable not set\n", .{});
        std.debug.print("Example: export ATLASSIAN_URL=https://your-domain.atlassian.net\n", .{});
        return err;
    };
    defer allocator.free(base_url);

    const username = std.process.getEnvVarOwned(allocator, "ATLASSIAN_USERNAME") catch |err| {
        std.debug.print("Error: ATLASSIAN_USERNAME environment variable not set\n", .{});
        return err;
    };
    defer allocator.free(username);

    const api_token = std.process.getEnvVarOwned(allocator, "ATLASSIAN_API_TOKEN") catch |err| {
        std.debug.print("Error: ATLASSIAN_API_TOKEN environment variable not set\n", .{});
        return err;
    };
    defer allocator.free(api_token);

    const is_cloud_str = std.process.getEnvVarOwned(allocator, "ATLASSIAN_CLOUD") catch "true";
    defer if (!std.mem.eql(u8, is_cloud_str, "true")) allocator.free(is_cloud_str);
    const is_cloud = std.mem.eql(u8, is_cloud_str, "true");

    // Initialize client
    var client = AtlassianClient.init(allocator, base_url, username, api_token, is_cloud);
    defer client.deinit();

    // Dispatch to service handler
    // ConfluenceコマンドにはベースURLを渡してURLを動的に生成
    switch (service) {
        .jira => try handleJiraCommand(allocator, &client, args[2..]),
        .confluence => try handleConfluenceCommand(allocator, &client, args[2..], base_url),
    }
}
