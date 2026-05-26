# Third-Party Notices

This repository contains installer scripts. The scripts install third-party packages and services at runtime. Third-party software is not vendored in this repository unless explicitly stated.

This file is a practical notice, not legal advice. Verify licenses before redistributing modified packages, Docker images, bundled virtual environments, or generated release artifacts.

## Python and MCP runtime packages

The installers may install these Python packages into per-server virtual environments:

| Package | Used by | Notes / license pointer |
|---|---|---|
| `mcp` | all servers | Model Context Protocol Python SDK; PyPI metadata lists MIT. |
| `starlette` | all servers | ASGI framework; BSD-3-Clause. |
| `uvicorn` | all servers | ASGI server; license should be verified from package metadata for the installed version. |
| `httpx` | weather, wiki verifier, web | HTTP client; license should be verified from package metadata for the installed version. |
| `pydantic` | contacts, memory | Data validation; license should be verified from package metadata for the installed version. |
| `pypdf` | files | PDF reading; license should be verified from package metadata for the installed version. |
| `weasyprint` | files | HTML/PDF rendering; license should be verified from package metadata for the installed version. |
| `markdown` / Python-Markdown | files | Markdown conversion; BSD-3-Clause. |
| `latex2mathml` | files | LaTeX math to MathML conversion; license should be verified from package metadata for the installed version. |
| `trafilatura` | web | Web text extraction; GPL-3.0 according to upstream/PyPI pages. |

To generate a license report from an installed environment, you can use a tool such as `pip-licenses`:

```bash
source ~/mcp_server_tools/mcp_basic_web/.venv/bin/activate
pip install pip-licenses
pip-licenses --format=markdown
```

## Containerized components

### SearXNG

`mcp_basic_web.sh` runs SearXNG in Docker.

SearXNG is licensed under AGPL-3.0 according to the upstream project. The installer uses the public SearXNG container image and does not vendor SearXNG source code in this repository.

If you redistribute a modified SearXNG image or expose a modified SearXNG service, review AGPL-3.0 obligations carefully.

## External data/services

### Open-Meteo

`mcp_basic_weather.sh` uses Open-Meteo APIs. Open-Meteo states that non-commercial API use is free up to a daily request limit and requires attribution under the CC BY 4.0 data license. Review Open-Meteo terms before heavy, commercial, or redistributed use.

### Wikipedia and Wikidata

`mcp_basic_wiki_verifier.sh` uses public Wikimedia APIs. Review Wikimedia API etiquette, rate limits, and data/content licenses when building larger applications or redistributing data.

### Search engines through SearXNG

`mcp_basic_web.sh` queries search engines through SearXNG. Search results may be subject to the terms of the upstream search engines used by your SearXNG configuration.

## System packages

The installers use system package managers (`pacman` or `apt-get`) to install Linux packages such as Python, Docker, Cairo/Pango libraries, fonts, and SQLite support. Those packages retain their distribution-provided licenses.
