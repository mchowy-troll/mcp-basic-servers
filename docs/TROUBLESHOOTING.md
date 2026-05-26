# Troubleshooting

## Service does not start

Check status:

```bash
systemctl status mcp-basic-weather.service
```

Read recent logs:

```bash
journalctl -u mcp-basic-weather.service -n 80 --no-pager
```

Follow logs live:

```bash
journalctl -u mcp-basic-weather.service -f
```

## Port is busy

Check which process uses the port:

```bash
sudo ss -ltnp | grep ':8006'
```

Run the installer again and choose another port, or stop the earlier matching service when prompted.

## `uv` is missing

The installer can install `uv` for the current user. If that fails, install it manually and ensure the binary is on `PATH`.

Check:

```bash
command -v uv
```

## Docker or SearXNG problems

For `mcp_basic_web.sh`, check Docker:

```bash
docker info
```

If Docker requires sudo:

```bash
sudo docker info
```

Check SearXNG logs:

```bash
cd ~/mcp_server_tools/mcp_basic_web/searxng
docker compose logs --tail 80
```

or:

```bash
cd ~/mcp_server_tools/mcp_basic_web/searxng
sudo docker compose logs --tail 80
```

Test SearXNG locally:

```bash
curl -fsS 'http://127.0.0.1:8081/search?q=test&format=json' | head
```

Use the SearXNG port selected during installation if it is not `8081`.

## MCP endpoint returns unexpected HTTP output

MCP over Streamable HTTP may not behave like a normal webpage in a browser. Prefer testing through an MCP client.

The installer also checks whether the local service port responds.

## Model says it has no internet

If `mcp_basic_web.sh` is installed and `web_search` works, this is usually a client/model instruction issue.

Add a system/client instruction such as:

```text
For current, recent, today’s, latest, price, weather, news, or time-sensitive questions, call datetime_get first if the current date is needed, then call web_search before answering.
```

Then test again with:

```text
sprawdź proszę informacje z kraju i ze świata dziś
```

## Generated files are in the wrong language

The installer language is always English. The language choice affects only MCP tool descriptions.

Re-run the installer and choose another language when prompted:

```text
Choice [default: 2]:
```

## Timezone is wrong

The installer detects timezone automatically using:

1. `timedatectl`
2. `/etc/timezone`
3. `/etc/localtime` symlink
4. fallback: `UTC`

Check your system timezone:

```bash
timedatectl
```

Then re-run the installer if needed.
