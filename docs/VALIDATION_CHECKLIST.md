# Validation Checklist

Use this checklist before publishing a release.

## Script presence

Final scripts expected in the repository root:

```text
mcp_basic_web.sh
mcp_basic_files.sh
mcp_basic_memory.sh
mcp_basic_contacts.sh
mcp_basic_wiki_verifier.sh
mcp_basic_weather.sh
```

## Static checks

Run:

```bash
bash -n mcp_basic_web.sh
bash -n mcp_basic_files.sh
bash -n mcp_basic_memory.sh
bash -n mcp_basic_contacts.sh
bash -n mcp_basic_wiki_verifier.sh
bash -n mcp_basic_weather.sh
```

## Required defaults

```text
mcp_basic_web             8001
mcp_basic_files           8002
mcp_basic_memory          8003
mcp_basic_contacts        8004
mcp_basic_wiki_verifier   8005
mcp_basic_weather         8006
```

All scripts should use:

```text
FALLBACK_TIMEZONE="UTC"
TOOL_LANGUAGE="en"
```

## Runtime standard

All scripts should preserve:

```text
/mcp
Mount("/", app=mcp.streamable_http_app())
FastMCP + Starlette + Streamable HTTP
```

All systemd services should use:

```text
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
uvicorn server:app --host 0.0.0.0 --port ${MCP_PORT}
```

## Directory policy

| Server | Creates workspace | Creates database | Notes |
|---|---:|---:|---|
| web | no | no | creates `searxng/` inside project |
| files | yes | no | uses `mcp_workspace` |
| memory | no | yes | uses SQLite in `mcp_database` and backups in `mcp_backups/memory_backups` |
| contacts | no | yes | uses SQLite in `mcp_database` and backups in `mcp_backups/contacts_backups` |
| wiki_verifier | no | no | external APIs only |
| weather | no | no | external APIs only |

## Functional smoke tests

After installation, check each service:

```bash
systemctl status mcp-basic-web.service
systemctl status mcp-basic-files.service
systemctl status mcp-basic-memory.service
systemctl status mcp-basic-contacts.service
systemctl status mcp-basic-wiki-verifier.service
systemctl status mcp-basic-weather.service
```

Recommended LLM-side tool tests:

- web: `datetime_get`, `web_search`, `webpage_fetch`, `server_info_web`
- files: text read/write, CSV read/write, Markdown save, PDF save
- memory: write, search by exact title, get context, update, stats, backup, delete
- contacts: create, search, get, update, resolve recipient, backup, delete
- wiki verifier: resolve entity, get Wikidata facts, get Wikipedia article, answer context
- weather: geocode city, current weather, hourly forecast, daily forecast
