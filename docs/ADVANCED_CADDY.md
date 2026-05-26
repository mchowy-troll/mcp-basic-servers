# Optional Caddy Notes

Caddy is not installed or configured by these scripts.

The default and recommended setup is direct MCP HTTP access:

```text
http://127.0.0.1:<port>/mcp
http://<LAN_IP>:<port>/mcp
```

If you already use Caddy and understand reverse proxies, you can place it in front of MCP servers yourself.

Prefer separate local hostnames instead of path rewriting:

```text
http://mcp-web.local/mcp
http://mcp-files.local/mcp
http://mcp-weather.local/mcp
```

Avoid complex subpath routing unless your MCP client is known to handle it correctly.

Important:

- Do not change the MCP server endpoint inside the generated Python server.
- Keep `/mcp` as the MCP endpoint path.
- Do not rewrite MCP session headers.
- Do not expose these services publicly without additional authentication and network controls.
