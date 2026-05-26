# Installation Guide

## Before you start

Run installers as a regular user, not as root.

The installers use `sudo` only where system changes are required, such as installing packages and creating systemd services.

Supported systems:

- Arch-based Linux with `pacman`
- Ubuntu-based Linux with `apt-get`
- `systemd`

## Install one server

Example for weather:

```bash
chmod +x mcp_basic_weather.sh
./mcp_basic_weather.sh
```

The installer asks for:

```text
Port [default: 8006]:
Choice [default: 2]:
```

The language choice controls MCP tool descriptions:

```text
1) Polski
2) English
3) Deutsch
4) Français
5) Italiano
6) Español
```

The installer language itself is English.

## Install all servers

Install the scripts one by one:

```bash
chmod +x mcp_basic_web.sh
./mcp_basic_web.sh

chmod +x mcp_basic_files.sh
./mcp_basic_files.sh

chmod +x mcp_basic_memory.sh
./mcp_basic_memory.sh

chmod +x mcp_basic_contacts.sh
./mcp_basic_contacts.sh

chmod +x mcp_basic_wiki_verifier.sh
./mcp_basic_wiki_verifier.sh

chmod +x mcp_basic_weather.sh
./mcp_basic_weather.sh
```

Default ports:

```text
mcp_basic_web             8001
mcp_basic_files           8002
mcp_basic_memory          8003
mcp_basic_contacts        8004
mcp_basic_wiki_verifier   8005
mcp_basic_weather         8006
```

If a port is busy and the matching earlier service is running, the installer can stop that service and continue. Otherwise choose a different port.

## Web server and SearXNG

`mcp_basic_web.sh` additionally asks for a local SearXNG port:

```text
SearXNG port [default: 8081]:
```

SearXNG is intended as a local backend for the MCP web server. MCP clients should connect to:

```text
http://127.0.0.1:8001/mcp
```

not directly to SearXNG.

## Where files are installed

Base directory:

```text
~/mcp_server_tools/
```

Per-server project directory:

```text
~/mcp_server_tools/mcp_basic_<name>/
```

Typical layout:

```text
~/mcp_server_tools/mcp_basic_<name>/
  .env
  .venv/
  app/
    server.py
```

Additional shared directories:

```text
~/mcp_server_tools/mcp_workspace/   # files server only
~/mcp_server_tools/mcp_database/    # memory and contacts only
```

## After installation

Use the endpoint printed by the installer:

```text
http://127.0.0.1:<port>/mcp
```

For LAN access:

```text
http://<LAN_IP>:<port>/mcp
```

Check service status:

```bash
systemctl status mcp-basic-weather.service
```

Follow service logs:

```bash
journalctl -u mcp-basic-weather.service -f
```

## Reinstall or update

Run the same installer again. It will rewrite the generated `server.py`, `.env`, virtual environment, and systemd service for that server.

For database-backed servers, data is stored outside the generated application directory:

```text
~/mcp_server_tools/mcp_database/
```

Review and back up this directory before destructive maintenance.
