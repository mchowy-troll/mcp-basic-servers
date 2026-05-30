# MCP Client Configuration Notes

Use the MCP endpoint printed by the installer.

Local endpoint pattern:

```text
http://127.0.0.1:<port>/mcp
```

LAN endpoint pattern:

```text
http://<LAN_IP>:<port>/mcp
```

## Recommended client instruction for live information

Some LLMs may default to saying they cannot access current information even when the MCP web tools are available. Add an instruction like this to your client/system prompt:

```text
For current, recent, today’s, latest, price, weather, news, or time-sensitive questions, call datetime_get first if the current date is needed, then call web_search before answering. Use webpage_fetch to read a specific result URL when more detail is needed.
```

## Suggested usage by task

| User need | Recommended tool sequence |
|---|---|
| Today’s news | `datetime_get` → `web_search` |
| Current price or exchange rate | `datetime_get` → `web_search` |
| Weather by coordinates/city | `weather_by_city` or `weather_current` |
| Verify a known entity | `resolve_entity` → `get_entity_bundle` or `answer_context` |
| Save a local note/file | `txt_save` or `markdown_save` |
| Read a local workspace file | `txt_read`, `csv_read` |
| Remember a fact/decision | `memory_write` |
| Recall project/user context | `memory_search` or `memory_get_context` |
| Back up local memory SQLite database | `memory_backup` |
| Resolve a person/contact | contact search or recipient resolution tools |
| Back up local contacts SQLite database | `contacts_backup` |

Backup tools write only to their fixed backup directories under `~/mcp_server_tools/mcp_backups/`. The model cannot choose backup paths, file names, or subdirectories.

## Notes on dates

If your model has an internal date that differs from the actual system date, call `datetime_get` before answering time-sensitive questions. This helps avoid confusion when search results contain dates newer than the model's built-in knowledge.
