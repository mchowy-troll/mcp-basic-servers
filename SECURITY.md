# Security Policy

## Scope

This project provides local installer scripts for MCP servers exposed over HTTP on a Linux machine.

The servers are intended primarily for local/home use and trusted LAN environments. They are not hardened as public internet services.

## Supported use

Recommended deployment:

```text
LLM client -> http://127.0.0.1:<port>/mcp
```

or, for trusted local network use:

```text
LLM client on LAN -> http://<LAN_IP>:<port>/mcp
```

Avoid exposing these MCP endpoints directly to the public internet.

## Sensitive files

Each installer writes runtime configuration to `.env` under the project directory:

```text
~/mcp_server_tools/mcp_basic_<name>/.env
```

The web installer stores a SearXNG secret in `.env` and should keep this file readable only by the owner, for example:

```bash
chmod 600 ~/mcp_server_tools/mcp_basic_web/.env
```

## Network exposure

The MCP services bind to `0.0.0.0` so they can be used from another trusted machine in the local network.

`mcp_basic_web.sh` runs SearXNG locally for the MCP server. SearXNG should be bound to `127.0.0.1` only; clients should connect to MCP, not directly to SearXNG.

## Tool-specific considerations

### `mcp_basic_files`

The file server is limited to a workspace directory and rejects absolute paths and subdirectories. Treat the workspace as data controlled by the LLM client.

### `mcp_basic_memory` and `mcp_basic_contacts`

These servers store local SQLite data. Back up or delete the database files according to your own privacy needs:

```text
~/mcp_server_tools/mcp_database/
```

### `mcp_basic_web`

The web server can fetch external webpages. Web content may contain prompt injection or misleading information. LLM clients should treat fetched content as untrusted source material.

### `mcp_basic_wiki_verifier`

Wikipedia/Wikidata data can be incomplete or stale. Use it as a verification aid, not as an authority for fast-changing facts.

## Reporting security issues

If you publish this repository, add your preferred security contact here.

Please report security issues by opening a private security advisory on GitHub if the repository has that feature enabled. Do not include secrets, private data, or database dumps in public issues.
