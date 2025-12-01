# Atlassian CLI

Command-line interface for Atlassian Jira and Confluence written in Zig.

## Features

- **Jira Operations**: Search issues, manage projects, track sprints and boards
- **Confluence Operations**: Search pages, manage spaces, view comments and labels
- **Fast**: Built with Zig for minimal overhead
- **Simple**: Straightforward command-line interface
- **Secure**: Uses API tokens for authentication

## Prerequisites

- Zig 0.15.2 or later
- Atlassian account with API token
- Jira and/or Confluence instance

## Installation

```bash
# Clone the repository
git clone https://github.com/ainoya/atlassian-cli.git
cd atlassian-cli

# Build
zig build

# Install (optional)
zig build install
```

The binary will be available at `./zig-out/bin/atlassian-cli`

## Configuration

Set the following environment variables:

```bash
export ATLASSIAN_URL="https://your-domain.atlassian.net"
export ATLASSIAN_USERNAME="your-email@example.com"
export ATLASSIAN_API_TOKEN="your-api-token"
export ATLASSIAN_CLOUD="true"  # true for Cloud, false for Server/DC
```

### Creating an API Token

1. Go to https://id.atlassian.com/manage-profile/security/api-tokens
2. Click "Create API token"
3. Give it a name and copy the token
4. Use this token as `ATLASSIAN_API_TOKEN`

### Using direnv (recommended)

Create a `.envrc` file in the project directory:

```bash
export ATLASSIAN_URL="https://your-domain.atlassian.net"
export ATLASSIAN_USERNAME="your-email@example.com"
export ATLASSIAN_API_TOKEN="your-api-token"
export ATLASSIAN_CLOUD="true"
```

Then run:
```bash
direnv allow
```

## Usage

### General Syntax

```bash
atlassian-cli <service> <command> [options]
```

### Jira Commands

#### Get Issue
```bash
atlassian-cli jira issue PROJECT-123
```

#### Search Issues
```bash
# Basic JQL search
atlassian-cli jira search "project=DEV AND status=Open"

# With max results
atlassian-cli jira search "assignee=currentUser()" --max=50

# Recent issues
atlassian-cli jira search "created >= -7d ORDER BY created DESC" --max=20
```

#### List Projects
```bash
atlassian-cli jira projects
```

#### Get Project Issues
```bash
atlassian-cli jira project-issues DEV --max=20
```

#### List Agile Boards
```bash
# All boards
atlassian-cli jira boards

# Scrum boards only
atlassian-cli jira boards --type=scrum

# Kanban boards only
atlassian-cli jira boards --type=kanban
```

#### List Sprints
```bash
# All sprints for board
atlassian-cli jira sprints 123

# Active sprints only
atlassian-cli jira sprints 123 --state=active

# Closed sprints
atlassian-cli jira sprints 123 --state=closed
```

#### Get Sprint Issues
```bash
atlassian-cli jira sprint-issues 456 --max=50
```

#### Get Current User
```bash
atlassian-cli jira user
```

### Confluence Commands

#### Get Page
```bash
atlassian-cli confluence page 123456
```

#### Search Pages
```bash
# Simple CQL search
atlassian-cli confluence search "type=page AND space=DEV"

# Search with limit
atlassian-cli confluence search "siteSearch ~ \"documentation\"" --limit=20

# Date range
atlassian-cli confluence search "created >= \"2024-01-01\" AND space=TEAM" --limit=10
```

#### List Spaces
```bash
atlassian-cli confluence spaces --limit=50
```

#### Get Space Details
```bash
atlassian-cli confluence space DEV
```

#### Get Child Pages
```bash
atlassian-cli confluence children 123456 --limit=25
```

#### Get Page Comments
```bash
atlassian-cli confluence comments 123456
```

#### Get Page Labels
```bash
atlassian-cli confluence labels 123456
```

## JQL Examples

Jira Query Language (JQL) examples for searching:

```bash
# Issues assigned to you
"assignee=currentUser()"

# Open bugs in specific project
"project=PROJ AND issuetype=Bug AND status=Open"

# Updated in last 7 days
"updated >= -7d"

# High priority issues
"priority=High ORDER BY created DESC"

# Issues with specific labels
"labels=urgent"

# Date range
"created >= \"2024-01-01\" AND created <= \"2024-12-31\""
```

## CQL Examples

Confluence Query Language (CQL) examples for searching:

```bash
# Pages in specific space
"type=page AND space=DEV"

# Text search
"siteSearch ~ \"important concept\""

# Pages with specific label
"type=page AND label=documentation"

# Recent pages
"type=page AND created >= \"2024-01-01\""

# Pages by specific user
"type=page AND creator=john.doe"

# Personal space search (requires quoting)
"type=page AND space=\"~username\""
```

## Using with Claude Code

This CLI is designed to work seamlessly as a Claude Code skill.

### Skill Setup

The CLI is already configured as a Claude Skill. The skill definition is located at:

```
.claude/skills/atlassian-search/SKILL.md
```

### Using the Skill

Once the binary is built, Claude Code will automatically detect and use the skill. Simply ask Claude to:

- "Search Jira for open bugs in project DEV"
- "Find Confluence documentation about API authentication"
- "Show me issues assigned to me in the current sprint"
- "Search for security-related pages in Confluence"

### Manual Usage Examples

You can also use the CLI directly:

```bash
# Search Jira issues
atlassian-cli jira search "assignee=currentUser() AND status=Open"

# Search Confluence
atlassian-cli confluence text-search "API documentation" --full-content

# Get issue details
atlassian-cli jira issue PROJECT-123
```

### Programmatic Usage

For programmatic integration:

```typescript
import { exec } from 'child_process';
import { promisify } from 'util';

const execAsync = promisify(exec);

async function searchJiraIssues(jql: string) {
  const { stdout } = await execAsync(`atlassian-cli jira search "${jql}" --format=json`);
  return JSON.parse(stdout);
}

async function getConfluencePage(pageId: string) {
  const { stdout } = await execAsync(`atlassian-cli confluence page ${pageId} --format=json`);
  return JSON.parse(stdout);
}
```

## Output Format

All commands output JSON, making it easy to parse and process the results:

```bash
# Pretty print with jq
atlassian-cli jira issue PROJECT-123 | jq

# Extract specific fields
atlassian-cli jira search "project=DEV" | jq '.issues[].key'

# Count results
atlassian-cli confluence spaces | jq '.results | length'
```

## Development

### Build
```bash
zig build
```

### Run without installing
```bash
zig build run -- jira projects
zig build run -- confluence spaces
```

### Run tests
```bash
zig build test
```

## Architecture

The CLI is structured in layers:

- **atlassian_client.zig**: Core HTTP client with Basic Auth
- **jira_client.zig**: Jira-specific API methods
- **confluence_client.zig**: Confluence-specific API methods
- **main.zig**: CLI argument parsing and command routing

## API Coverage

### Jira
- ✅ Get issue details
- ✅ Search with JQL
- ✅ List projects
- ✅ Get project issues
- ✅ List agile boards
- ✅ List sprints
- ✅ Get sprint issues
- ✅ Get current user

### Confluence
- ✅ Get page by ID
- ✅ Search with CQL
- ✅ List spaces
- ✅ Get space details
- ✅ Get child pages
- ✅ Get page comments
- ✅ Get page labels

## Troubleshooting

### Authentication Errors

If you get `401 Unauthorized`:
- Verify your `ATLASSIAN_API_TOKEN` is correct
- Check that `ATLASSIAN_USERNAME` is your email address
- Ensure the token hasn't expired

### Permission Errors

If you get `403 Forbidden`:
- Check your user has the required permissions
- Verify you have access to the project/space
- Contact your Atlassian admin if needed

### Not Found Errors

If you get `404 Not Found`:
- Verify the issue key, page ID, or space key is correct
- Check you have permission to view the resource
- Ensure you're using the correct `ATLASSIAN_URL`

## License

MIT

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## References

- [Jira REST API Documentation](https://developer.atlassian.com/cloud/jira/platform/rest/v3/)
- [Confluence REST API Documentation](https://developer.atlassian.com/cloud/confluence/rest/v1/)
- [JQL Documentation](https://support.atlassian.com/jira-service-management-cloud/docs/use-advanced-search-with-jira-query-language-jql/)
- [CQL Documentation](https://developer.atlassian.com/cloud/confluence/advanced-searching-using-cql/)
