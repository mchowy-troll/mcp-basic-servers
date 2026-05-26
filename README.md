# MCP Basic Servers

A small collection of self-contained installer scripts for local/home MCP servers exposed over HTTP.

The goal is simple: run one script, answer a few questions, get a working MCP endpoint such as:

```text
http://127.0.0.1:8001/mcp
http://192.168.x.x:8001/mcp
```

The scripts are designed for moderately technical Linux users who want practical local MCP tools without manually creating Python virtual environments, systemd services, Docker compose files, ports, and runtime configuration.

## Included servers

| Script | Default port | Purpose | Extra storage |
|---|---:|---|---|
| `mcp_basic_web.sh` | `8001` | Provides live web access for LLM clients through a local SearXNG instance. It can search for current news, recent events, prices, exchange rates, software updates, and other time-sensitive information, then fetch and extract readable text from specific webpages when deeper source context is needed. | Docker/SearXNG directory inside the project |
| `mcp_basic_files.sh` | `8002` | Gives the model a safe local workspace for practical file tasks: reading and writing text files, working with CSV data, saving Markdown notes, and generating PDFs from Markdown without exposing arbitrary filesystem paths. | `~/mcp_server_tools/mcp_workspace/` |
| `mcp_basic_memory.sh` | `8003` | Provides a local long-term memory store backed by SQLite. It lets the model write structured memory records, search them by title/content/tags, retrieve relevant context, update records, delete records, and inspect memory statistics. | `~/mcp_server_tools/mcp_database/` |
| `mcp_basic_contacts.sh` | `8004` | Provides a local contacts database for people, companies, email addresses, phone numbers, addresses, notes, and tags. It helps the model search contacts, resolve recipients, check whether a contact exists, and manage contact records locally. | `~/mcp_server_tools/mcp_database/` |
| `mcp_basic_wiki_verifier.sh` | `8005` | Helps verify factual background about entities using Wikidata and English Wikipedia. It can resolve names to candidate entities, fetch structured Wikidata facts, retrieve article context, and build a source-backed context bundle for fact-checking or disambiguation. | none |
| `mcp_basic_weather.sh` | `8006` | Provides weather tools based on Open-Meteo: geocoding cities, checking current weather by coordinates or city, and retrieving hourly or daily forecasts with practical limits for home/local assistant use. | none |

## Supported systems

The installers support:

- Arch-based Linux systems with `pacman`
- Ubuntu-based Linux systems with `apt-get`
- `systemd`
- Python 3
- `uv` for Python environments

If `uv` is missing, the installer asks whether it should install `uv` for the current user.

## Quick start

Download or clone the repository, then run one installer as a regular user:

```bash
chmod +x mcp_basic_weather.sh
./mcp_basic_weather.sh
```

Do not run the installers as root. They call `sudo` only where needed.

During installation, each script asks only for the necessary choices:

```text
Port [default: 8006]:
Choice [default: 2]:
```

`mcp_basic_web.sh` also asks for the local SearXNG port:

```text
SearXNG port [default: 8081]:
```

The language choice controls MCP tool descriptions, not the installer language. The installer is intentionally always in English.

Available MCP tool description languages:

1. Polski
2. English
3. Deutsch
4. Français
5. Italiano
6. Español

## Runtime layout

Each server is installed under:

```text
~/mcp_server_tools/mcp_basic_<name>/
  .env
  .venv/
  app/
    server.py
```

Shared directories are created only when needed:

```text
~/mcp_server_tools/mcp_workspace/   # only for files
~/mcp_server_tools/mcp_database/    # only for memory and contacts
```

`mcp_basic_web.sh` additionally creates:

```text
~/mcp_server_tools/mcp_basic_web/searxng/
```

## Connecting from an MCP client

Use the endpoint printed at the end of installation:

```text
http://127.0.0.1:<port>/mcp
```

For other machines in the same LAN, use:

```text
http://<LAN_IP>:<port>/mcp
```

The transport and endpoint are intentionally stable across all servers:

```text
/mcp
```

## Useful commands

Check service status:

```bash
systemctl status mcp-basic-weather.service
```

Follow logs:

```bash
journalctl -u mcp-basic-weather.service -f
```

For the web server, follow SearXNG logs from its project directory:

```bash
cd ~/mcp_server_tools/mcp_basic_web/searxng
docker compose logs -f
```

If the installer used `sudo docker`, use:

```bash
sudo docker compose logs -f
```

## Current-date and live-web guidance for LLM clients

For current, recent, today’s, latest, price, weather, news, or time-sensitive questions, configure your LLM client to use:

1. `datetime_get` when the current date/time matters.
2. `web_search` before answering questions that may require fresh information.
3. `webpage_fetch` to read a specific result URL in more detail.

A useful client/system instruction is:

```text
For current, recent, today’s, latest, price, weather, news, or time-sensitive questions, call datetime_get first if the current date is needed, then call web_search before answering.
```

## Documentation

- [Installation guide](docs/INSTALLATION.md)
- [Server reference](docs/SERVERS.md)
- [Client configuration notes](docs/CLIENT_CONFIGURATION.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Optional Caddy notes](docs/ADVANCED_CADDY.md)
- [Validation checklist](docs/VALIDATION_CHECKLIST.md)
- [Security policy](SECURITY.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)

## License

This repository is licensed under the MIT License. Third-party dependencies and services keep their own licenses and terms. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
