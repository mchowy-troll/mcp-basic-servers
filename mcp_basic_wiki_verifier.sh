#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_NAME="mcp_basic_wiki_verifier"
PROJECT_ROOT_DIR_NAME="mcp_server_tools"
PROJECT_DIR_NAME="mcp_basic_wiki_verifier"
SERVER_FILE_NAME="server.py"
SERVICE_NAME="mcp-basic-wiki-verifier.service"
DEFAULT_MCP_PORT="8005"
FALLBACK_TIMEZONE="UTC"
PYTHON_BIN="python3"
ENV_FILE_NAME=".env"

USER_NAME="${SUDO_USER:-$(whoami)}"
USER_HOME="$(getent passwd "${USER_NAME}" | cut -d: -f6)"
ROOT_DIR="${USER_HOME}/${PROJECT_ROOT_DIR_NAME}"
BASE_DIR="${ROOT_DIR}/${PROJECT_DIR_NAME}"
APP_DIR="${BASE_DIR}/app"
VENV_DIR="${BASE_DIR}/.venv"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
ENV_FILE="${BASE_DIR}/${ENV_FILE_NAME}"

LINUX_FAMILY=""
MCP_PORT="${DEFAULT_MCP_PORT}"
DEFAULT_TIMEZONE="${FALLBACK_TIMEZONE}"
TOOL_LANGUAGE="en"
UV_BIN=""

log() {
  printf '\n==> %s\n' "$*"
}

info() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARNING] %s\n' "$*"
}

fail() {
  printf '\n[ERROR] %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

ensure_user_context() {
  if [[ "${EUID}" -eq 0 ]]; then
    fail "Run this script as a regular user, not as root. The installer will use sudo when needed."
  fi

  if [[ -z "${USER_HOME}" || ! -d "${USER_HOME}" ]]; then
    fail "Could not detect the home directory for user ${USER_NAME}."
  fi

  if [[ "$(id -un)" != "${USER_NAME}" ]]; then
    fail "The current user does not match the target installation user (${USER_NAME})."
  fi
}

detect_linux_family() {
  if command -v pacman >/dev/null 2>&1; then
    LINUX_FAMILY="arch"
  elif command -v apt-get >/dev/null 2>&1; then
    LINUX_FAMILY="ubuntu"
  else
    fail "This installer supports Arch-based Linux and Ubuntu-based Linux."
  fi
}

install_system_packages() {
  case "${LINUX_FAMILY}" in
    arch)
      log "Installing system packages with pacman"
      sudo pacman -S --needed --noconfirm \
        curl ca-certificates python uv tzdata
      ;;
    ubuntu)
      log "Installing system packages with apt"
      sudo apt-get update
      sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        curl ca-certificates python3 python3-venv python3-pip tzdata
      ;;
    *)
      fail "Unknown Linux family: ${LINUX_FAMILY}"
      ;;
  esac
}

ensure_uv() {
  if command -v uv >/dev/null 2>&1; then
    UV_BIN="$(command -v uv)"
    return 0
  fi

  warn "uv was not found. It is needed to create the Python environment."
  printf 'Install uv for the current user? [default: Y]: '
  local answer
  read -r answer
  answer="${answer:-Y}"

  case "${answer}" in
    Y|y|yes|Yes)
      log "Installing uv for the current user"
      curl -LsSf https://astral.sh/uv/install.sh | sh
      export PATH="${USER_HOME}/.local/bin:${PATH}"
      ;;
    *)
      fail "The installer cannot continue without uv. Install uv and run this script again."
      ;;
  esac

  if ! command -v uv >/dev/null 2>&1; then
    fail "uv installation was not detected. Check whether ${USER_HOME}/.local/bin is in PATH."
  fi

  UV_BIN="$(command -v uv)"
}

detect_lan_ip() {
  "${PYTHON_BIN}" - <<'PY'
import contextlib
import ipaddress
import socket

ip = "127.0.0.1"
with contextlib.suppress(Exception):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.connect(("8.8.8.8", 80))
    candidate = sock.getsockname()[0]
    sock.close()
    if ipaddress.ip_address(candidate).is_private:
        ip = candidate
print(ip)
PY
}

port_is_free() {
  local port="$1"
  "${PYTHON_BIN}" - "${port}" <<'PY'
import socket
import sys

port = int(sys.argv[1])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    sock.bind(("0.0.0.0", port))
except OSError:
    raise SystemExit(1)
finally:
    sock.close()
PY
}

service_exists() {
  [[ -f "${SERVICE_FILE}" ]] || systemctl list-unit-files --type=service --all 2>/dev/null | awk '{print $1}' | grep -Fxq "${SERVICE_NAME}"
}

maybe_stop_existing_service_for_port() {
  if ! service_exists; then
    return 1
  fi

  if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
    return 1
  fi

  warn "The port is busy, but an earlier version of ${SERVICE_NAME} is running."
  printf 'Stop this service for the update and check the port again? [default: Y]: '
  local answer
  read -r answer
  answer="${answer:-Y}"

  case "${answer}" in
    Y|y|yes|Yes)
      sudo systemctl stop "${SERVICE_NAME}" || true
      sleep 1
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

prompt_mcp_port() {
  log "MCP port selection"
  printf 'Default port for %s is %s.\n' "${PROJECT_NAME}" "${DEFAULT_MCP_PORT}"

  local selected
  while true; do
    printf 'Port [default: %s]: ' "${DEFAULT_MCP_PORT}"
    read -r selected
    selected="${selected:-${DEFAULT_MCP_PORT}}"

    if [[ ! "${selected}" =~ ^[0-9]+$ ]]; then
      warn "Port must be a number."
      continue
    fi

    if (( selected < 1024 || selected > 65535 )); then
      warn "Choose a port in the range 1024-65535."
      continue
    fi

    if port_is_free "${selected}"; then
      MCP_PORT="${selected}"
      return 0
    fi

    if maybe_stop_existing_service_for_port && port_is_free "${selected}"; then
      MCP_PORT="${selected}"
      return 0
    fi

    warn "Port ${selected} is busy. Choose another port."
  done
}

prompt_tool_language() {
  log "Tool description language selection"
  cat <<'EOF'
Choose the language for MCP tool descriptions:

1) Polski
2) English
3) Deutsch
4) Français
5) Italiano
6) Español
EOF

  local choice
  while true; do
    printf 'Choice [default: 2]: '
    read -r choice
    choice="${choice:-2}"

    case "${choice}" in
      1|pl|PL|polski|Polski) TOOL_LANGUAGE="pl"; return 0 ;;
      2|en|EN|english|English) TOOL_LANGUAGE="en"; return 0 ;;
      3|de|DE|deutsch|Deutsch) TOOL_LANGUAGE="de"; return 0 ;;
      4|fr|FR|francais|français|Francais|Français) TOOL_LANGUAGE="fr"; return 0 ;;
      5|it|IT|italiano|Italiano) TOOL_LANGUAGE="it"; return 0 ;;
      6|es|ES|espanol|español|Espanol|Español) TOOL_LANGUAGE="es"; return 0 ;;
      *) warn "Choose a number from 1 to 6 or a language code: pl, en, de, fr, it, es." ;;
    esac
  done
}

valid_timezone() {
  local timezone="$1"
  [[ -n "${timezone}" ]] || return 1

  "${PYTHON_BIN}" - "${timezone}" <<'PY'
import sys
from zoneinfo import ZoneInfo

try:
    ZoneInfo(sys.argv[1])
except Exception:
    raise SystemExit(1)
PY
}

read_etc_timezone() {
  [[ -r /etc/timezone ]] || return 1

  awk '
    /^[[:space:]]*#/ { next }
    NF { gsub(/[[:space:]]/, ""); print; exit }
  ' /etc/timezone
}

detect_system_timezone() {
  local candidate=""

  if command -v timedatectl >/dev/null 2>&1; then
    candidate="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    if valid_timezone "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  fi

  candidate="$(read_etc_timezone 2>/dev/null || true)"
  if valid_timezone "${candidate}"; then
    printf '%s\n' "${candidate}"
    return 0
  fi

  if [[ -L /etc/localtime ]]; then
    candidate="$(readlink /etc/localtime | sed 's#^.*zoneinfo/##')"
    if valid_timezone "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  fi

  printf '%s\n' "${FALLBACK_TIMEZONE}"
}

set_timezone_from_system() {
  DEFAULT_TIMEZONE="$(detect_system_timezone)"
}

create_directories() {
  log "Creating application directory"
  mkdir -p "${APP_DIR}"
}

write_env_file() {
  log "Writing configuration file"
  cat > "${ENV_FILE}" <<EOF
PROJECT_NAME=${PROJECT_NAME}
PROJECT_ROOT_DIR_NAME=${PROJECT_ROOT_DIR_NAME}
PROJECT_DIR_NAME=${PROJECT_DIR_NAME}
USER_NAME=${USER_NAME}
USER_HOME=${USER_HOME}
ROOT_DIR=${ROOT_DIR}
BASE_DIR=${BASE_DIR}
APP_DIR=${APP_DIR}
VENV_DIR=${VENV_DIR}
MCP_PORT=${MCP_PORT}
DEFAULT_TIMEZONE=${DEFAULT_TIMEZONE}
TOOL_LANGUAGE=${TOOL_LANGUAGE}
WIKIPEDIA_API_BASE=https://en.wikipedia.org/w/api.php
WIKIPEDIA_REST_BASE=https://en.wikipedia.org/api/rest_v1
WIKIDATA_API_BASE=https://www.wikidata.org/w/api.php
WIKIDATA_ENTITY_BASE=https://www.wikidata.org/wiki/Special:EntityData
USER_AGENT=${PROJECT_NAME}/1.0
EOF
}

create_virtualenv() {
  log "Creating Python environment"
  "${UV_BIN}" venv "${VENV_DIR}"

  log "Installing Python dependencies"
  "${UV_BIN}" pip install --python "${VENV_DIR}/bin/python" \
    mcp starlette uvicorn httpx
}

write_python_server() {
  log "Writing MCP server Python file"
  cat > "${APP_DIR}/${SERVER_FILE_NAME}" <<'PY'
from __future__ import annotations

import contextlib
import ipaddress
import os
import re
import socket
from pathlib import Path
from typing import Any

import httpx
from mcp.server.fastmcp import FastMCP
from starlette.applications import Starlette
from starlette.middleware.cors import CORSMiddleware
from starlette.routing import Mount

PROJECT_NAME = os.environ.get("PROJECT_NAME", "mcp_basic_wiki_verifier")
DEFAULT_TIMEZONE = os.environ.get("DEFAULT_TIMEZONE", "UTC")
TOOL_LANGUAGE = os.environ.get("TOOL_LANGUAGE", "en").strip().lower()
MCP_PORT = int(os.environ.get("MCP_PORT", "8005"))
BASE_DIR = Path(
    os.environ.get("BASE_DIR", str(Path.home() / "mcp_server_tools" / "mcp_basic_wiki_verifier"))
).resolve()

WIKIPEDIA_API_BASE = os.environ.get("WIKIPEDIA_API_BASE", "https://en.wikipedia.org/w/api.php")
WIKIPEDIA_REST_BASE = os.environ.get("WIKIPEDIA_REST_BASE", "https://en.wikipedia.org/api/rest_v1")
WIKIDATA_API_BASE = os.environ.get("WIKIDATA_API_BASE", "https://www.wikidata.org/w/api.php")
WIKIDATA_ENTITY_BASE = os.environ.get("WIKIDATA_ENTITY_BASE", "https://www.wikidata.org/wiki/Special:EntityData")
USER_AGENT = os.environ.get("USER_AGENT", f"{PROJECT_NAME}/1.0")

DEFAULT_WIKIPEDIA_MAX_CHARS = 12000
MAX_WIKIPEDIA_MAX_CHARS = 30000
DEFAULT_RESOLVE_LIMIT = 5
MAX_RESOLVE_LIMIT = 10
DEFAULT_WIKI_SECTION_LIMIT = 12
MAX_WIKI_SECTION_LIMIT = 30
DEFAULT_CONTEXT_CHARS = 2400
DEFAULT_EXTRACT_SENTENCES = 10

MCP_ENDPOINT_PATH = "/mcp"

SUPPORTED_TOOL_LANGUAGES = {"pl", "en", "de", "fr", "it", "es"}

TOOL_DESCRIPTIONS = {
    "pl": {
        "resolve_entity": "Wyszukuje encję w Wikidata i English Wikipedia oraz zwraca najlepsze dopasowania.\nMaksymalna liczba wyników: 1-10.",
        "get_wikidata_facts": "Zwraca strukturalne fakty z Wikidata dla wybranego QID.",
        "get_wikipedia_article": "Zwraca szerszy kontekst artykułu z English Wikipedia.\nMaksymalna długość treści: 200-30000 znaków.",
        "get_entity_bundle": "Rozwiązuje encję i zwraca połączony pakiet danych z Wikidata i English Wikipedia.\nMaksymalna długość treści z Wikipedii: 200-30000 znaków.",
        "answer_context": "Zwraca szeroki pakiet kontekstu przygotowany do odpowiedzi na pytanie.\nMaksymalna długość treści z Wikipedii: 200-30000 znaków.",
        "server_info_wiki_verifier": "Zwraca podstawowe informacje o serwerze wiki verifier i lokalne adresy MCP.",
    },
    "en": {
        "resolve_entity": "Searches Wikidata and English Wikipedia for an entity and returns the best matches.\nResults maximum count: 1-10.",
        "get_wikidata_facts": "Returns structured Wikidata facts for the selected QID.",
        "get_wikipedia_article": "Returns a larger English Wikipedia article context.\nContent maximum length: 200-30000 characters.",
        "get_entity_bundle": "Resolves an entity and returns a combined Wikidata and English Wikipedia data bundle.\nWikipedia content maximum length: 200-30000 characters.",
        "answer_context": "Returns a broad context package prepared for answering a question.\nWikipedia content maximum length: 200-30000 characters.",
        "server_info_wiki_verifier": "Returns basic wiki verifier server information and local MCP endpoints.",
    },
    "de": {
        "resolve_entity": "Sucht eine Entität in Wikidata und English Wikipedia und gibt die besten Treffer zurück.\nMaximale Ergebnisanzahl: 1-10.",
        "get_wikidata_facts": "Gibt strukturierte Wikidata-Fakten für die gewählte QID zurück.",
        "get_wikipedia_article": "Gibt einen größeren Artikelkontext aus der English Wikipedia zurück.\nMaximale Inhaltslänge: 200-30000 Zeichen.",
        "get_entity_bundle": "Löst eine Entität auf und gibt ein kombiniertes Datenpaket aus Wikidata und English Wikipedia zurück.\nMaximale Wikipedia-Inhaltslänge: 200-30000 Zeichen.",
        "answer_context": "Gibt ein breites Kontextpaket zurück, das für die Beantwortung einer Frage vorbereitet ist.\nMaximale Wikipedia-Inhaltslänge: 200-30000 Zeichen.",
        "server_info_wiki_verifier": "Gibt grundlegende Informationen zum Wiki-Verifier-Server und lokale MCP-Adressen zurück.",
    },
    "fr": {
        "resolve_entity": "Recherche une entité dans Wikidata et English Wikipedia et retourne les meilleurs résultats.\nNombre maximal de résultats : 1-10.",
        "get_wikidata_facts": "Retourne des faits Wikidata structurés pour le QID choisi.",
        "get_wikipedia_article": "Retourne un contexte plus large d'article depuis English Wikipedia.\nLongueur maximale du contenu : 200-30000 caractères.",
        "get_entity_bundle": "Résout une entité et retourne un paquet de données combiné depuis Wikidata et English Wikipedia.\nLongueur maximale du contenu Wikipédia : 200-30000 caractères.",
        "answer_context": "Retourne un large paquet de contexte préparé pour répondre à une question.\nLongueur maximale du contenu Wikipédia : 200-30000 caractères.",
        "server_info_wiki_verifier": "Retourne les informations de base du serveur wiki verifier et les adresses MCP locales.",
    },
    "it": {
        "resolve_entity": "Cerca un'entità in Wikidata e English Wikipedia e restituisce le migliori corrispondenze.\nNumero massimo di risultati: 1-10.",
        "get_wikidata_facts": "Restituisce fatti strutturati da Wikidata per il QID scelto.",
        "get_wikipedia_article": "Restituisce un contesto più ampio di un articolo da English Wikipedia.\nLunghezza massima del contenuto: 200-30000 caratteri.",
        "get_entity_bundle": "Risolve un'entità e restituisce un pacchetto dati combinato da Wikidata e English Wikipedia.\nLunghezza massima del contenuto Wikipedia: 200-30000 caratteri.",
        "answer_context": "Restituisce un ampio pacchetto di contesto preparato per rispondere a una domanda.\nLunghezza massima del contenuto Wikipedia: 200-30000 caratteri.",
        "server_info_wiki_verifier": "Restituisce le informazioni di base del server wiki verifier e gli indirizzi MCP locali.",
    },
    "es": {
        "resolve_entity": "Busca una entidad en Wikidata y English Wikipedia y devuelve las mejores coincidencias.\nCantidad máxima de resultados: 1-10.",
        "get_wikidata_facts": "Devuelve hechos estructurados de Wikidata para el QID elegido.",
        "get_wikipedia_article": "Devuelve un contexto más amplio de un artículo de English Wikipedia.\nLongitud máxima del contenido: 200-30000 caracteres.",
        "get_entity_bundle": "Resuelve una entidad y devuelve un paquete de datos combinado de Wikidata y English Wikipedia.\nLongitud máxima del contenido de Wikipedia: 200-30000 caracteres.",
        "answer_context": "Devuelve un paquete amplio de contexto preparado para responder una pregunta.\nLongitud máxima del contenido de Wikipedia: 200-30000 caracteres.",
        "server_info_wiki_verifier": "Devuelve información básica del servidor wiki verifier y direcciones MCP locales.",
    },
}

PREFERRED_PROPERTIES = {
    "P31": "instance_of",
    "P279": "subclass_of",
    "P17": "country",
    "P131": "located_in_administrative_territorial_entity",
    "P159": "headquarters_location",
    "P571": "inception",
    "P569": "date_of_birth",
    "P570": "date_of_death",
    "P106": "occupation",
    "P39": "position_held",
    "P856": "official_website",
    "P178": "developer",
    "P176": "manufacturer",
    "P123": "publisher",
    "P50": "author",
    "P361": "part_of",
    "P155": "follows",
    "P156": "followed_by",
    "P407": "language_of_work_or_name",
    "P495": "country_of_origin",
    "P27": "country_of_citizenship",
    "P1082": "population",
    "P625": "coordinate_location",
}

DYNAMIC_PROPERTY_IDS = {"P39", "P1082", "P571", "P155", "P156", "P159"}
DYNAMIC_QUERY_HINTS = {
    "current",
    "latest",
    "today",
    "now",
    "recent",
    "recently",
    "currently",
    "present",
    "incumbent",
    "newest",
}
DYNAMIC_ENTITY_HINTS = {
    "company",
    "business",
    "organization",
    "politician",
    "office",
    "position",
    "software",
    "product",
    "ai model",
    "language model",
}

mcp = FastMCP(
    PROJECT_NAME,
    stateless_http=True,
    json_response=True,
    host="0.0.0.0",
)


def _tool_description(tool_name: str) -> str:
    language = TOOL_LANGUAGE if TOOL_LANGUAGE in SUPPORTED_TOOL_LANGUAGES else "en"
    return TOOL_DESCRIPTIONS[language][tool_name]


def _detect_local_ip() -> str:
    with contextlib.suppress(Exception):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.connect(("8.8.8.8", 80))
        ip = sock.getsockname()[0]
        sock.close()
        if ipaddress.ip_address(ip).is_private:
            return ip
    return "127.0.0.1"


def _build_client() -> httpx.Client:
    return httpx.Client(
        timeout=30.0,
        headers={
            "User-Agent": USER_AGENT,
            "Accept": "application/json",
        },
        follow_redirects=True,
    )


def _clean_whitespace(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def _truncate_text(text: str, max_chars: int) -> str:
    safe_max = max(200, min(int(max_chars), MAX_WIKIPEDIA_MAX_CHARS))
    if len(text) <= safe_max:
        return text
    return text[: safe_max - 1].rstrip() + "…"


def _normalize_query(text: str) -> str:
    return _clean_whitespace(text).lower()


def _parse_wikidata_time(value: str) -> str:
    if not value:
        return value
    parsed = value.strip()
    parsed = parsed.lstrip("+")
    if parsed.startswith("0000"):
        return value
    return parsed.rstrip("Z")


def _extract_plain_text_from_html(html: str) -> str:
    if not html:
        return ""
    text = re.sub(r"<style.*?>.*?</style>", " ", html, flags=re.IGNORECASE | re.DOTALL)
    text = re.sub(r"<script.*?>.*?</script>", " ", text, flags=re.IGNORECASE | re.DOTALL)
    text = re.sub(r"<sup[^>]*class=\"reference\"[^>]*>.*?</sup>", " ", text, flags=re.IGNORECASE | re.DOTALL)
    text = re.sub(r"<[^>]+>", " ", text)
    text = (
        text.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&quot;", '"')
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
    )
    return _clean_whitespace(text)


def _safe_json_get(url: str, *, params: dict[str, Any] | None = None) -> dict[str, Any]:
    with _build_client() as client:
        response = client.get(url, params=params)
        response.raise_for_status()
        return response.json()


def _wikipedia_search(query: str, limit: int = DEFAULT_RESOLVE_LIMIT) -> list[dict[str, Any]]:
    safe_limit = max(1, min(int(limit), MAX_RESOLVE_LIMIT))
    payload = _safe_json_get(
        WIKIPEDIA_API_BASE,
        params={
            "action": "query",
            "list": "search",
            "srsearch": query,
            "srlimit": safe_limit,
            "format": "json",
            "utf8": 1,
            "origin": "*",
        },
    )
    results: list[dict[str, Any]] = []
    for item in payload.get("query", {}).get("search", []) or []:
        results.append(
            {
                "title": item.get("title"),
                "pageid": item.get("pageid"),
                "snippet": _clean_whitespace(re.sub(r"<[^>]+>", " ", item.get("snippet", ""))),
                "timestamp": item.get("timestamp"),
                "wordcount": item.get("wordcount"),
            }
        )
    return results


def _wikidata_search_entities(query: str, limit: int = DEFAULT_RESOLVE_LIMIT) -> list[dict[str, Any]]:
    safe_limit = max(1, min(int(limit), MAX_RESOLVE_LIMIT))
    payload = _safe_json_get(
        WIKIDATA_API_BASE,
        params={
            "action": "wbsearchentities",
            "search": query,
            "language": "en",
            "uselang": "en",
            "type": "item",
            "limit": safe_limit,
            "format": "json",
            "origin": "*",
        },
    )
    results: list[dict[str, Any]] = []
    for item in payload.get("search", []) or []:
        results.append(
            {
                "qid": item.get("id"),
                "label": item.get("label"),
                "description": item.get("description"),
                "match": item.get("match", {}),
                "aliases": item.get("aliases", []),
                "concepturi": item.get("concepturi"),
                "repository": item.get("repository"),
                "url": item.get("url"),
            }
        )
    return results


def _get_wikidata_entity(qid: str) -> dict[str, Any]:
    payload = _safe_json_get(
        WIKIDATA_API_BASE,
        params={
            "action": "wbgetentities",
            "ids": qid,
            "languages": "en",
            "format": "json",
            "props": "labels|descriptions|aliases|claims|sitelinks|info",
            "origin": "*",
        },
    )
    return (payload.get("entities") or {}).get(qid, {})


def _get_wikipedia_summary(title: str) -> dict[str, Any]:
    url = f"{WIKIPEDIA_REST_BASE}/page/summary/{httpx.QueryParams({'t': title})['t']}"
    payload = _safe_json_get(url)
    return {
        "title": payload.get("title", title),
        "displaytitle": payload.get("displaytitle", title),
        "description": payload.get("description"),
        "extract": payload.get("extract", ""),
        "extract_html": payload.get("extract_html", ""),
        "content_urls": payload.get("content_urls", {}),
        "thumbnail": payload.get("thumbnail"),
        "timestamp": payload.get("timestamp"),
        "pageid": payload.get("pageid"),
    }


def _get_wikipedia_parse(title: str) -> dict[str, Any]:
    payload = _safe_json_get(
        WIKIPEDIA_API_BASE,
        params={
            "action": "parse",
            "page": title,
            "prop": "text|sections|displaytitle|revid",
            "format": "json",
            "utf8": 1,
            "origin": "*",
        },
    )
    return payload.get("parse", {}) or {}


def _get_wikipedia_page_info(title: str) -> dict[str, Any]:
    payload = _safe_json_get(
        WIKIPEDIA_API_BASE,
        params={
            "action": "query",
            "prop": "revisions|info",
            "titles": title,
            "rvprop": "timestamp|ids",
            "inprop": "url",
            "format": "json",
            "utf8": 1,
            "origin": "*",
        },
    )
    pages = payload.get("query", {}).get("pages", {}) or {}
    page = next(iter(pages.values()), {}) if pages else {}
    revisions = page.get("revisions", []) or []
    latest_revision = revisions[0] if revisions else {}
    return {
        "pageid": page.get("pageid"),
        "title": page.get("title", title),
        "fullurl": page.get("fullurl"),
        "canonicalurl": page.get("canonicalurl"),
        "lastrevid": page.get("lastrevid") or latest_revision.get("revid"),
        "last_updated": latest_revision.get("timestamp"),
    }


def _extract_section_titles(parse_payload: dict[str, Any], limit: int = DEFAULT_WIKI_SECTION_LIMIT) -> list[dict[str, Any]]:
    safe_limit = max(1, min(int(limit), MAX_WIKI_SECTION_LIMIT))
    sections = parse_payload.get("sections", []) or []
    return [
        {
            "number": item.get("number"),
            "index": item.get("index"),
            "line": item.get("line"),
            "anchor": item.get("anchor"),
            "level": item.get("level"),
        }
        for item in sections[:safe_limit]
    ]


def _extract_context_snippet(text: str, terms: list[str], max_chars: int = DEFAULT_CONTEXT_CHARS) -> str:
    clean = _clean_whitespace(text)
    if not clean:
        return ""
    lower = clean.lower()
    positions = [lower.find(term.lower()) for term in terms if term and term.lower() in lower]
    positions = [pos for pos in positions if pos >= 0]
    if not positions:
        return _truncate_text(clean, max_chars)
    start = max(0, min(positions) - max_chars // 4)
    end = min(len(clean), start + max_chars)
    snippet = clean[start:end].strip()
    if start > 0:
        snippet = "…" + snippet
    if end < len(clean):
        snippet = snippet + "…"
    return snippet


def _pick_enwiki_title(entity: dict[str, Any]) -> str | None:
    sitelinks = entity.get("sitelinks", {}) or {}
    enwiki = sitelinks.get("enwiki") or {}
    return enwiki.get("title")


def _extract_aliases(entity: dict[str, Any], limit: int = 15) -> list[str]:
    aliases = ((entity.get("aliases") or {}).get("en") or [])[:limit]
    return [item.get("value") for item in aliases if item.get("value")]


def _extract_label(entity: dict[str, Any]) -> str | None:
    return ((entity.get("labels") or {}).get("en") or {}).get("value")


def _extract_description(entity: dict[str, Any]) -> str | None:
    return ((entity.get("descriptions") or {}).get("en") or {}).get("value")


def _snak_datavalue_to_python(datavalue: dict[str, Any] | None) -> Any:
    if not datavalue:
        return None
    value = datavalue.get("value")
    if isinstance(value, dict):
        if "id" in value:
            return {"id": value.get("id")}
        if "time" in value:
            return _parse_wikidata_time(value.get("time", ""))
        if "latitude" in value and "longitude" in value:
            return {
                "latitude": value.get("latitude"),
                "longitude": value.get("longitude"),
                "precision": value.get("precision"),
            }
        if "amount" in value:
            return {
                "amount": value.get("amount"),
                "unit": value.get("unit"),
            }
    return value


def _resolve_entity_labels_for_ids(ids: list[str]) -> dict[str, str]:
    clean_ids = [item for item in ids if item]
    if not clean_ids:
        return {}
    payload = _safe_json_get(
        WIKIDATA_API_BASE,
        params={
            "action": "wbgetentities",
            "ids": "|".join(sorted(set(clean_ids))),
            "languages": "en",
            "format": "json",
            "props": "labels",
            "origin": "*",
        },
    )
    entities = payload.get("entities", {}) or {}
    mapping: dict[str, str] = {}
    for qid, entity in entities.items():
        label = ((entity.get("labels") or {}).get("en") or {}).get("value")
        if label:
            mapping[qid] = label
    return mapping


def _extract_preferred_facts(entity: dict[str, Any]) -> dict[str, list[Any]]:
    claims = entity.get("claims", {}) or {}
    referenced_entity_ids: list[str] = []
    raw: dict[str, list[Any]] = {}

    for prop_id, output_key in PREFERRED_PROPERTIES.items():
        prop_claims = claims.get(prop_id, []) or []
        values: list[Any] = []
        for claim in prop_claims[:8]:
            mainsnak = claim.get("mainsnak", {}) or {}
            datavalue = mainsnak.get("datavalue")
            value = _snak_datavalue_to_python(datavalue)
            if value is None:
                continue
            if isinstance(value, dict) and "id" in value:
                referenced_entity_ids.append(value["id"])
            values.append(value)
        if values:
            raw[output_key] = values

    labels_by_id = _resolve_entity_labels_for_ids(referenced_entity_ids)
    cooked: dict[str, list[Any]] = {}
    for key, values in raw.items():
        new_values: list[Any] = []
        for value in values:
            if isinstance(value, dict) and "id" in value:
                qid = value["id"]
                new_values.append({"id": qid, "label": labels_by_id.get(qid, qid)})
            else:
                new_values.append(value)
        cooked[key] = new_values
    return cooked


def _entity_bundle_from_qid(qid: str, wikipedia_max_chars: int = DEFAULT_WIKIPEDIA_MAX_CHARS) -> dict[str, Any]:
    entity = _get_wikidata_entity(qid)
    if not entity:
        return {"error": f"Nie znaleziono encji Wikidata dla {qid}"}

    label = _extract_label(entity)
    description = _extract_description(entity)
    aliases = _extract_aliases(entity)
    enwiki_title = _pick_enwiki_title(entity)
    facts = _extract_preferred_facts(entity)

    wikipedia_summary: dict[str, Any] | None = None
    wikipedia_page: dict[str, Any] | None = None
    wikipedia_extract = ""
    wikipedia_sections: list[dict[str, Any]] = []
    wikipedia_error: str | None = None

    if enwiki_title:
        with contextlib.suppress(Exception):
            wikipedia_summary = _get_wikipedia_summary(enwiki_title)
        try:
            parse_payload = _get_wikipedia_parse(enwiki_title)
            page_info = _get_wikipedia_page_info(enwiki_title)
            html_text = ((parse_payload.get("text") or {}).get("*") or "")
            plain_text = _extract_plain_text_from_html(html_text)
            wikipedia_extract = _truncate_text(plain_text, wikipedia_max_chars)
            wikipedia_sections = _extract_section_titles(parse_payload)
            wikipedia_page = {
                "title": page_info.get("title", enwiki_title),
                "displaytitle": parse_payload.get("displaytitle") or enwiki_title,
                "pageid": page_info.get("pageid"),
                "fullurl": page_info.get("fullurl"),
                "canonicalurl": page_info.get("canonicalurl"),
                "lastrevid": page_info.get("lastrevid"),
                "last_updated": page_info.get("last_updated"),
            }
        except Exception as exc:
            wikipedia_error = str(exc)

    entity_url = f"https://www.wikidata.org/wiki/{qid}"
    freshness = _freshness_risk(
        query=label or qid,
        facts=facts,
        wikipedia_last_updated=(wikipedia_page or {}).get("last_updated"),
        description=description or "",
    )

    return {
        "qid": qid,
        "label": label,
        "description": description,
        "aliases": aliases,
        "wikidata_url": entity_url,
        "wikipedia_title": enwiki_title,
        "facts": facts,
        "wikipedia_summary": wikipedia_summary,
        "wikipedia_article": {
            **(wikipedia_page or {}),
            "extract": wikipedia_extract,
            "sections": wikipedia_sections,
        }
        if enwiki_title
        else None,
        "freshness": freshness,
        "notes": {
            "wikipedia_error": wikipedia_error,
            "claim_count": sum(len(v) for v in (entity.get("claims", {}) or {}).values()),
            "sitelink_count": len(entity.get("sitelinks", {}) or {}),
        },
    }


def _resolve_best_entity(query: str, limit: int = DEFAULT_RESOLVE_LIMIT) -> dict[str, Any]:
    wiki_results = _wikipedia_search(query, limit=limit)
    wikidata_results = _wikidata_search_entities(query, limit=limit)

    score_map: dict[str, dict[str, Any]] = {}
    normalized_query = _normalize_query(query)

    for rank, item in enumerate(wikidata_results, start=1):
        qid = item.get("qid")
        if not qid:
            continue
        label = item.get("label") or ""
        description = item.get("description") or ""
        aliases = item.get("aliases") or []
        score = max(0.0, 1.0 - ((rank - 1) * 0.08))
        if _normalize_query(label) == normalized_query:
            score += 0.2
        if normalized_query in _normalize_query(description):
            score += 0.05
        if any(_normalize_query(alias) == normalized_query for alias in aliases):
            score += 0.1
        score_map[qid] = {
            "qid": qid,
            "label": label,
            "description": description,
            "aliases": aliases,
            "wikipedia_title": None,
            "score": round(min(score, 0.99), 3),
            "wikidata_result": item,
            "wikipedia_result": None,
        }

    wiki_by_title = {item.get("title"): item for item in wiki_results if item.get("title")}

    for qid, payload in list(score_map.items()):
        try:
            entity = _get_wikidata_entity(qid)
        except Exception:
            continue
        title = _pick_enwiki_title(entity)
        if title:
            payload["wikipedia_title"] = title
            if title in wiki_by_title:
                payload["wikipedia_result"] = wiki_by_title[title]
                payload["score"] = round(min(payload["score"] + 0.08, 0.995), 3)

    for rank, item in enumerate(wiki_results, start=1):
        title = item.get("title")
        if not title:
            continue
        already = next((row for row in score_map.values() if row.get("wikipedia_title") == title), None)
        if already:
            continue
        score = max(0.0, 0.72 - ((rank - 1) * 0.07))
        score_map[f"wiki:{title}"] = {
            "qid": None,
            "label": title,
            "description": item.get("snippet"),
            "aliases": [],
            "wikipedia_title": title,
            "score": round(score, 3),
            "wikidata_result": None,
            "wikipedia_result": item,
        }

    ranked = sorted(score_map.values(), key=lambda x: x.get("score", 0), reverse=True)[:limit]
    selected = ranked[0] if ranked else None
    return {
        "query": query,
        "candidates": ranked,
        "selected": selected,
        "counts": {
            "wikidata_candidates": len(wikidata_results),
            "wikipedia_candidates": len(wiki_results),
        },
    }


def _freshness_risk(query: str, facts: dict[str, list[Any]], wikipedia_last_updated: str | None, description: str) -> dict[str, Any]:
    score = 0
    notes: list[str] = []
    q = _normalize_query(query)
    d = _normalize_query(description)

    if any(token in q for token in DYNAMIC_QUERY_HINTS):
        score += 2
        notes.append("query looks time-sensitive")

    if any(token in d for token in DYNAMIC_ENTITY_HINTS):
        score += 1
        notes.append("entity type may change over time")

    for prop_id, key in PREFERRED_PROPERTIES.items():
        if prop_id in DYNAMIC_PROPERTY_IDS and facts.get(key):
            score += 1
            notes.append(f"contains dynamic property: {key}")

    if wikipedia_last_updated:
        notes.append("wikipedia timestamp available")
    else:
        score += 1
        notes.append("missing wikipedia timestamp")

    if score >= 4:
        risk = "high"
    elif score >= 2:
        risk = "medium"
    else:
        risk = "low"

    return {
        "risk": risk,
        "score": score,
        "wikipedia_last_updated": wikipedia_last_updated,
        "notes": notes,
    }


def _match_claim_against_facts(claim: str, bundle: dict[str, Any]) -> dict[str, Any]:
    claim_norm = _normalize_query(claim)
    facts = bundle.get("facts") or {}
    evidence: list[dict[str, Any]] = []
    status = "not_found"

    property_aliases = {
        "founded": "inception",
        "founded in": "inception",
        "born": "date_of_birth",
        "died": "date_of_death",
        "occupation": "occupation",
        "headquartered": "headquarters_location",
        "headquarters": "headquarters_location",
        "developer": "developer",
        "manufacturer": "manufacturer",
        "publisher": "publisher",
        "author": "author",
        "country": "country",
        "citizenship": "country_of_citizenship",
        "website": "official_website",
        "instance of": "instance_of",
        "is a": "instance_of",
    }

    matched_keys = [value for alias, value in property_aliases.items() if alias in claim_norm]
    if not matched_keys:
        matched_keys = list(facts.keys())

    for key in matched_keys:
        values = facts.get(key) or []
        for value in values:
            text_value = value.get("label") if isinstance(value, dict) and "label" in value else str(value)
            if text_value and _normalize_query(str(text_value)) in claim_norm:
                status = "confirmed"
                evidence.append({"source": "wikidata", "property": key, "value": value})
            elif key in claim_norm:
                evidence.append({"source": "wikidata", "property": key, "value": value})
                if status == "not_found":
                    status = "partially_confirmed"

    wiki_article = bundle.get("wikipedia_article") or {}
    wiki_text = wiki_article.get("extract") or ""
    if wiki_text:
        terms = [bundle.get("label") or ""]
        for key in matched_keys:
            terms.append(key.replace("_", " "))
        wiki_snippet = _extract_context_snippet(wiki_text, [t for t in terms if t])
        if wiki_snippet:
            evidence.append({"source": "wikipedia", "snippet": wiki_snippet})
            if status == "not_found":
                status = "partially_confirmed"

    return {
        "claim": claim,
        "status": status,
        "matched_entity": {
            "qid": bundle.get("qid"),
            "label": bundle.get("label"),
            "wikipedia_title": bundle.get("wikipedia_title"),
        },
        "evidence": evidence,
        "freshness": bundle.get("freshness"),
    }


@mcp.tool(name="resolve_entity", description=_tool_description("resolve_entity"))
def resolve_entity(query: str, limit: int = DEFAULT_RESOLVE_LIMIT) -> dict[str, Any]:
    """Wyszukuje encję w Wikidata i English Wikipedia oraz zwraca najlepsze dopasowania."""
    return _resolve_best_entity(query=query, limit=limit)


@mcp.tool(name="get_wikidata_facts", description=_tool_description("get_wikidata_facts"))
def get_wikidata_facts(qid: str) -> dict[str, Any]:
    """Zwraca bogatszy zestaw faktów strukturalnych z Wikidata dla podanego QID."""
    entity = _get_wikidata_entity(qid)
    if not entity:
        return {"error": f"Nie znaleziono encji Wikidata dla {qid}"}

    return {
        "qid": qid,
        "label": _extract_label(entity),
        "description": _extract_description(entity),
        "aliases": _extract_aliases(entity),
        "wikipedia_title": _pick_enwiki_title(entity),
        "facts": _extract_preferred_facts(entity),
        "wikidata_url": f"https://www.wikidata.org/wiki/{qid}",
        "claim_count": sum(len(v) for v in (entity.get("claims", {}) or {}).values()),
        "sitelink_count": len(entity.get("sitelinks", {}) or {}),
    }


@mcp.tool(name="get_wikipedia_article", description=_tool_description("get_wikipedia_article"))
def get_wikipedia_article(
    title: str,
    max_chars: int = DEFAULT_WIKIPEDIA_MAX_CHARS,
    include_summary: bool = True,
    include_extract: bool = True,
    include_sections: bool = True,
) -> dict[str, Any]:
    """Pobiera większy kontekst artykułu z English Wikipedia zamiast wyłącznie krótkiego summary."""
    page_info = _get_wikipedia_page_info(title)
    result: dict[str, Any] = {
        "title": page_info.get("title", title),
        "pageid": page_info.get("pageid"),
        "fullurl": page_info.get("fullurl"),
        "canonicalurl": page_info.get("canonicalurl"),
        "lastrevid": page_info.get("lastrevid"),
        "last_updated": page_info.get("last_updated"),
    }

    if include_summary:
        with contextlib.suppress(Exception):
            result["summary"] = _get_wikipedia_summary(title)

    if include_extract or include_sections:
        parse_payload = _get_wikipedia_parse(title)
        if include_sections:
            result["sections"] = _extract_section_titles(parse_payload)
        if include_extract:
            html_text = ((parse_payload.get("text") or {}).get("*") or "")
            result["extract"] = _truncate_text(_extract_plain_text_from_html(html_text), max_chars)

    return result


@mcp.tool(name="get_entity_bundle", description=_tool_description("get_entity_bundle"))
def get_entity_bundle(query: str, wikipedia_max_chars: int = DEFAULT_WIKIPEDIA_MAX_CHARS) -> dict[str, Any]:
    """Rozwiązuje encję i zwraca bogaty pakiet danych z Wikidata i English Wikipedia."""
    resolution = _resolve_best_entity(query=query, limit=DEFAULT_RESOLVE_LIMIT)
    selected = resolution.get("selected")
    if not selected:
        return {
            "query": query,
            "resolution": resolution,
            "error": "Nie udało się dopasować encji.",
        }

    qid = selected.get("qid")
    if qid:
        bundle = _entity_bundle_from_qid(qid=qid, wikipedia_max_chars=wikipedia_max_chars)
    else:
        title = selected.get("wikipedia_title") or selected.get("label")
        article = get_wikipedia_article(title=title, max_chars=wikipedia_max_chars)
        bundle = {
            "qid": None,
            "label": selected.get("label"),
            "description": selected.get("description"),
            "aliases": selected.get("aliases") or [],
            "wikidata_url": None,
            "wikipedia_title": title,
            "facts": {},
            "wikipedia_summary": article.get("summary"),
            "wikipedia_article": article,
            "freshness": _freshness_risk(
                query=query,
                facts={},
                wikipedia_last_updated=article.get("last_updated"),
                description=selected.get("description") or "",
            ),
            "notes": {"fallback": "wikipedia_only"},
        }

    return {
        "query": query,
        "resolution": resolution,
        "bundle": bundle,
    }


@mcp.tool(name="answer_context", description=_tool_description("answer_context"))
def answer_context(query: str, wikipedia_max_chars: int = DEFAULT_WIKIPEDIA_MAX_CHARS) -> dict[str, Any]:
    """Zwraca wygodny, szeroki pakiet kontekstowy do odpowiedzi modelu."""
    payload = get_entity_bundle(query=query, wikipedia_max_chars=wikipedia_max_chars)
    bundle = payload.get("bundle") or {}
    summary_text = ((bundle.get("wikipedia_summary") or {}).get("extract") or "")
    recommended_mode = "answer_normally"
    freshness = (bundle.get("freshness") or {}).get("risk")
    if freshness == "medium":
        recommended_mode = "answer_with_caveat"
    elif freshness == "high":
        recommended_mode = "answer_with_strong_caveat"

    return {
        "query": query,
        "entity": {
            "qid": bundle.get("qid"),
            "label": bundle.get("label"),
            "description": bundle.get("description"),
            "wikipedia_title": bundle.get("wikipedia_title"),
        },
        "summary": summary_text,
        "facts": bundle.get("facts") or {},
        "article": bundle.get("wikipedia_article") or {},
        "aliases": bundle.get("aliases") or [],
        "freshness": bundle.get("freshness"),
        "recommended_answer_mode": recommended_mode,
        "raw": payload,
    }


@mcp.tool(name="server_info_wiki_verifier", description=_tool_description("server_info_wiki_verifier"))
def server_info_wiki_verifier() -> dict[str, Any]:
    """Zwraca podstawowe informacje o serwerze MCP."""
    local_ip = _detect_local_ip()
    return {
        "project_name": PROJECT_NAME,
        "base_dir": str(BASE_DIR),
        "mcp_endpoint_local": f"http://127.0.0.1:{MCP_PORT}{MCP_ENDPOINT_PATH}",
        "mcp_endpoint_lan": f"http://{local_ip}:{MCP_PORT}{MCP_ENDPOINT_PATH}",
        "timezone": DEFAULT_TIMEZONE,
        "tool_language": TOOL_LANGUAGE if TOOL_LANGUAGE in SUPPORTED_TOOL_LANGUAGES else "en",
        "sources": [
            "Wikidata API",
            "English Wikipedia Action API",
            "English Wikipedia REST API",
        ],
        "tools": [
            "resolve_entity",
            "get_wikidata_facts",
            "get_wikipedia_article",
            "get_entity_bundle",
            "answer_context",
            "server_info_wiki_verifier",
        ],
        "notes": [
            "The server keeps a simple reference-style structure.",
            "The MCP/Starlette transport section is intentionally kept in the same working style.",
            "Wikipedia payloads are larger than in the ultra-light version so the model receives richer context.",
        ],
    }


@contextlib.asynccontextmanager
async def lifespan(app: Starlette):
    async with mcp.session_manager.run():
        yield


app = Starlette(
    routes=[Mount("/", app=mcp.streamable_http_app())],
    lifespan=lifespan,
)

app = CORSMiddleware(
    app,
    allow_origins=["*"],
    allow_methods=["GET", "POST", "DELETE", "OPTIONS"],
    allow_headers=["*"],
    expose_headers=["Mcp-Session-Id"],
    allow_private_network=True,
)
PY
}

validate_generated_server() {
  log "Checking generated Python file"
  "${VENV_DIR}/bin/python" -m py_compile "${APP_DIR}/${SERVER_FILE_NAME}"
}

write_systemd_service() {
  log "Creating systemd service"
  cat > "/tmp/${SERVICE_NAME}" <<EOF
[Unit]
Description=${PROJECT_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${USER_NAME}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
Environment=PYTHONUNBUFFERED=1
ExecStart=${VENV_DIR}/bin/uvicorn ${SERVER_FILE_NAME%.*}:app --host 0.0.0.0 --port \${MCP_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  sudo mv "/tmp/${SERVICE_NAME}" "${SERVICE_FILE}"
  sudo systemctl daemon-reload
  sudo systemctl enable "${SERVICE_NAME}" >/dev/null
}

start_service() {
  log "Starting MCP service"
  sudo systemctl restart "${SERVICE_NAME}"
}

wait_for_port() {
  local attempt
  for attempt in $(seq 1 30); do
    if "${PYTHON_BIN}" - "${MCP_PORT}" <<'PY' >/dev/null 2>&1
import socket
import sys

port = int(sys.argv[1])
with socket.create_connection(("127.0.0.1", port), timeout=1.0):
    pass
PY
    then
      return 0
    fi
    sleep 1
  done
  return 1
}

test_service() {
  log "Checking whether the service is running"

  if ! sudo systemctl is-active --quiet "${SERVICE_NAME}"; then
    sudo journalctl -u "${SERVICE_NAME}" -n 40 --no-pager || true
    fail "Service ${SERVICE_NAME} did not start correctly."
  fi

  if ! wait_for_port; then
    sudo journalctl -u "${SERVICE_NAME}" -n 40 --no-pager || true
    fail "The service is running, but port ${MCP_PORT} does not respond locally."
  fi

  info "The service is running and port ${MCP_PORT} responds locally."
}


print_summary() {
  local lan_ip
  local summary_label_width=55
  local path_label_width=24
  lan_ip="$(detect_lan_ip)"

  printf '\nInstallation completed successfully.\n\n'

  printf '%-*s %s\n' "${summary_label_width}" 'MCP server name:' "${PROJECT_NAME}"
  printf '%-*s %s\n' "${summary_label_width}" 'MCP address on this computer:' "http://127.0.0.1:${MCP_PORT}/mcp"
  printf '%-*s %s\n' "${summary_label_width}" 'MCP address for other computers in the local network:' "http://${lan_ip}:${MCP_PORT}/mcp"
  printf '%-*s %s\n' "${summary_label_width}" 'Selected MCP tool description language:' "${TOOL_LANGUAGE}"
  printf '%-*s %s\n' "${summary_label_width}" 'Server timezone:' "${DEFAULT_TIMEZONE}"

  printf '\nProject directory structure:\n'
  printf '  %s\n' "${ROOT_DIR}"
  printf '  └── %s/\n' "${PROJECT_DIR_NAME}"
  printf '      ├── %s\n' "${ENV_FILE##*/}"
  printf '      ├── .venv/\n'
  printf '      └── app/\n'
  printf '          └── %s\n' "${SERVER_FILE_NAME}"

  printf '\nFull paths:\n'
  printf '  %-*s %s\n' "${path_label_width}" 'projects root directory:' "${ROOT_DIR}"
  printf '  %-*s %s\n' "${path_label_width}" 'project directory:' "${BASE_DIR}"
  printf '  %-*s %s\n' "${path_label_width}" 'application:' "${APP_DIR}"
  printf '  %-*s %s\n' "${path_label_width}" 'virtualenv:' "${VENV_DIR}"

  printf '\n'
  printf '  %-*s %s\n' "${path_label_width}" 'Service logs:' "journalctl -u ${SERVICE_NAME} -f"
  printf '  %-*s %s\n' "${path_label_width}" 'Service status:' "systemctl status ${SERVICE_NAME}"
}

main() {
  ensure_user_context
  require_command sudo
  require_command getent
  require_command systemctl

  detect_linux_family
  install_system_packages
  require_command curl
  require_command "${PYTHON_BIN}"
  ensure_uv

  prompt_mcp_port
  prompt_tool_language
  set_timezone_from_system

  create_directories
  write_env_file
  create_virtualenv
  write_python_server
  validate_generated_server
  write_systemd_service
  start_service
  test_service
  print_summary
}

main "$@"
