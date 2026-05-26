# Server Reference

## `mcp_basic_web.sh`

Default MCP port: `8001`

Purpose:

- live web search through local SearXNG
- webpage fetching and readable text extraction
- current date/time helper

Tools:

- `datetime_get`
- `web_search`
- `webpage_fetch`
- `server_info_web`

Storage:

```text
~/mcp_server_tools/mcp_basic_web/searxng/
```

No workspace or database directory is created for this server.

## `mcp_basic_files.sh`

Default MCP port: `8002`

Purpose:

- read and write workspace text files
- read and write CSV files
- save Markdown files
- generate PDFs from Markdown content

Tools:

- `file_datetime`
- `txt_read`
- `txt_save`
- `csv_read`
- `csv_save`
- `markdown_save`
- `pdf_save`
- `server_info_files`

Storage:

```text
~/mcp_server_tools/mcp_workspace/
```

The file tools are intentionally limited to simple file names in the workspace.

## `mcp_basic_memory.sh`

Default MCP port: `8003`

Purpose:

- local memory records
- search and context retrieval
- update/delete/statistics

Tools:

- `memory_write`
- `memory_search`
- `memory_get_context`
- `memory_update`
- `memory_delete`
- `memory_stats`
- `server_info_memory`

Storage:

```text
~/mcp_server_tools/mcp_database/memory_database.sqlite3
```

## `mcp_basic_contacts.sh`

Default MCP port: `8004`

Purpose:

- local contacts database
- search/update/delete contacts
- resolve a recipient by nickname, name, email, phone, company, or related fields

Tools include contact creation, search, get, update, delete, recipient resolution, existence checks, recent contact listing, and server info.

Storage:

```text
~/mcp_server_tools/mcp_database/contacts_database.sqlite3
```

## `mcp_basic_wiki_verifier.sh`

Default MCP port: `8005`

Purpose:

- Wikidata entity search and facts
- English Wikipedia article/context retrieval
- broader context packages for verification and answering

Tools:

- `resolve_entity`
- `get_wikidata_facts`
- `get_wikipedia_article`
- `get_entity_bundle`
- `answer_context`
- `server_info_wiki_verifier`

Storage: none.

## `mcp_basic_weather.sh`

Default MCP port: `8006`

Purpose:

- current weather
- hourly forecast
- daily forecast
- Open-Meteo geocoding
- weather by city

Tools:

- `weather_current`
- `weather_hourly`
- `weather_daily`
- `geocode_city`
- `weather_by_city`
- `server_info_weather`

Storage: none.
