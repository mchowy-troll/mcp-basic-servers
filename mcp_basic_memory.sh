#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_NAME="mcp_basic_memory"
PROJECT_ROOT_DIR_NAME="mcp_server_tools"
PROJECT_DIR_NAME="mcp_basic_memory"
SERVER_FILE_NAME="server.py"
SERVICE_NAME="mcp-basic-memory.service"
DEFAULT_MCP_PORT="8003"
FALLBACK_TIMEZONE="UTC"
PYTHON_BIN="python3"
ENV_FILE_NAME=".env"

USER_NAME="${SUDO_USER:-$(whoami)}"
USER_HOME="$(getent passwd "${USER_NAME}" | cut -d: -f6)"
ROOT_DIR="${USER_HOME}/${PROJECT_ROOT_DIR_NAME}"
BASE_DIR="${ROOT_DIR}/${PROJECT_DIR_NAME}"
APP_DIR="${BASE_DIR}/app"
VENV_DIR="${BASE_DIR}/.venv"
DATA_DIR="${ROOT_DIR}/mcp_database"
DB_PATH="${DATA_DIR}/memory_database.sqlite3"
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
        curl ca-certificates python uv tzdata sqlite
      ;;
    ubuntu)
      log "Installing system packages with apt"
      sudo apt-get update
      sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        curl ca-certificates python3 python3-venv python3-pip tzdata sqlite3
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
  log "Creating application and database directories"
  mkdir -p \
    "${APP_DIR}" \
    "${DATA_DIR}"
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
DATA_DIR=${DATA_DIR}
DB_PATH=${DB_PATH}
VENV_DIR=${VENV_DIR}
MCP_PORT=${MCP_PORT}
DEFAULT_TIMEZONE=${DEFAULT_TIMEZONE}
TOOL_LANGUAGE=${TOOL_LANGUAGE}
EOF
}

create_virtualenv() {
  log "Creating Python environment"
  "${UV_BIN}" venv "${VENV_DIR}"

  log "Installing Python dependencies"
  "${UV_BIN}" pip install --python "${VENV_DIR}/bin/python" \
    mcp starlette uvicorn "pydantic>=2,<3"
}

write_python_server() {
  log "Writing MCP server Python file"
  cat > "${APP_DIR}/${SERVER_FILE_NAME}" <<'PY'
from __future__ import annotations

import contextlib
import hashlib
import ipaddress
import json
import os
import re
import socket
import sqlite3
import threading
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo
from pathlib import Path
from typing import Any

from mcp.server.fastmcp import FastMCP
from pydantic import BaseModel, Field
from starlette.applications import Starlette
from starlette.middleware.cors import CORSMiddleware
from starlette.routing import Mount

PROJECT_NAME = os.environ.get("PROJECT_NAME", "mcp_basic_memory")
DEFAULT_TIMEZONE = os.environ.get("DEFAULT_TIMEZONE", "UTC")
BASE_DIR = Path(os.environ.get("BASE_DIR", str(Path.home() / "mcp_server_tools" / "mcp_basic_memory"))).resolve()
DATA_DIR = Path(os.environ.get("DATA_DIR", str(Path.home() / "mcp_server_tools" / "mcp_database"))).resolve()
DB_PATH = Path(os.environ.get("DB_PATH", str(DATA_DIR / "memory_database.sqlite3"))).resolve()
TOOL_LANGUAGE = os.environ.get("TOOL_LANGUAGE", "en").strip().lower()
MCP_PORT = int(os.environ.get("MCP_PORT", "8003"))

MAX_TITLE_LENGTH = 200
MAX_SUMMARY_LENGTH = 1000
MAX_CONTENT_LENGTH = 100000
MAX_TAGS = 24
MAX_TAG_LENGTH = 64
DEFAULT_CONTEXT_LIMIT = 8
DEFAULT_SEARCH_LIMIT = 10
MAX_SEARCH_LIMIT = 50
INPUT_DATE_FORMAT = "%d-%m-%Y"
INPUT_DATETIME_FORMAT = "%d-%m-%Y %H:%M:%S"
OUTPUT_LOCAL_DATETIME_FORMAT = "%d-%m-%Y %H:%M:%S"
ALLOWED_KINDS = {
    "fact",
    "preference",
    "decision",
    "summary",
    "task",
    "state",
    "project_rule",
    "profile",
}
KIND_ALIASES = {
    "event": "summary",
    "news": "summary",
    "conflict_summary": "summary",
    "observation": "fact",
    "rule": "project_rule",
    "setting": "preference",
    "user_profile": "profile",
    "plan": "task",
    "memory": "summary",
    "note": "summary",
    "notes": "summary",
    "information": "fact",
    "fakt": "fact",
    "informacja": "fact",
    "informacje": "summary",
    "notatka": "summary",
    "podsumowanie": "summary",
    "preferencja": "preference",
    "decyzja": "decision",
    "zadanie": "task",
    "reguła": "project_rule",
    "regula": "project_rule",
    "profil": "profile",
    "kursy_walut": "summary",
    "waluty": "summary",
    "obserwacja": "fact",
}
DB_LOCK = threading.Lock()

try:
    LOCAL_TIMEZONE = ZoneInfo(DEFAULT_TIMEZONE)
except Exception:
    LOCAL_TIMEZONE = timezone.utc

mcp = FastMCP(
    PROJECT_NAME,
    stateless_http=True,
    json_response=True,
    host="0.0.0.0",
)

SUPPORTED_TOOL_LANGUAGES = {"pl", "en", "de", "fr", "it", "es"}

TOOL_DESCRIPTIONS = {
    "pl": {
        "memory_write": "Zapisuje jeden rekord pamięci.\nMaksymalna długość podsumowania: 1000 znaków.\nMaksymalna długość treści: 100000 znaków.\nPoziom ważności: 1-10.",
        "memory_search": "Wyszukuje rekordy pamięci według tekstu i filtrów.\nMaksymalna liczba wyników: 1-50.",
        "memory_get_context": "Zwraca krótki kontekst z pamięci dopasowany do zapytania.",
        "memory_update": "Aktualizuje jeden rekord pamięci.\nMaksymalna długość podsumowania: 1000 znaków.\nMaksymalna długość treści: 100000 znaków.\nPoziom ważności: 1-10.",
        "memory_delete": "Trwale usuwa jeden rekord pamięci.",
        "memory_stats": "Zwraca statystyki pamięci i lokalne adresy MCP.",
        "server_info_memory": "Zwraca podstawowe informacje o serwerze pamięci i lokalne adresy MCP.",
    },
    "en": {
        "memory_write": "Write one memory record.\nSummary maximum length: 1000 characters.\nContent maximum length: 100000 characters.\nImportance range: 1-10.",
        "memory_search": "Search memory records with text and filters.\nResults maximum count: 1-50.",
        "memory_get_context": "Returns a compact memory context matched to the query.",
        "memory_update": "Update one memory record.\nSummary maximum length: 1000 characters.\nContent maximum length: 100000 characters.\nImportance range: 1-10.",
        "memory_delete": "Delete one memory record permanently.",
        "memory_stats": "Returns memory statistics and local MCP endpoints.",
        "server_info_memory": "Returns basic memory server information and local MCP endpoints.",
    },
    "de": {
        "memory_write": "Schreibt einen Speichereintrag.\nMaximale Länge der Zusammenfassung: 1000 Zeichen.\nMaximale Inhaltslänge: 100000 Zeichen.\nWichtigkeitsstufe: 1-10.",
        "memory_search": "Durchsucht Speichereinträge mit Text und Filtern.\nMaximale Ergebnisanzahl: 1-50.",
        "memory_get_context": "Gibt einen kompakten, zur Anfrage passenden Speicherkontext zurück.",
        "memory_update": "Aktualisiert einen Speichereintrag.\nMaximale Länge der Zusammenfassung: 1000 Zeichen.\nMaximale Inhaltslänge: 100000 Zeichen.\nWichtigkeitsstufe: 1-10.",
        "memory_delete": "Löscht einen Speichereintrag dauerhaft.",
        "memory_stats": "Gibt Speicherstatistiken und lokale MCP-Adressen zurück.",
        "server_info_memory": "Gibt grundlegende Informationen zum Speicherserver und lokale MCP-Adressen zurück.",
    },
    "fr": {
        "memory_write": "Écrit un enregistrement de mémoire.\nLongueur maximale du résumé : 1000 caractères.\nLongueur maximale du contenu : 100000 caractères.\nNiveau d'importance : 1-10.",
        "memory_search": "Recherche des enregistrements de mémoire avec du texte et des filtres.\nNombre maximal de résultats : 1-50.",
        "memory_get_context": "Retourne un contexte mémoire compact correspondant à la requête.",
        "memory_update": "Met à jour un enregistrement de mémoire.\nLongueur maximale du résumé : 1000 caractères.\nLongueur maximale du contenu : 100000 caractères.\nNiveau d'importance : 1-10.",
        "memory_delete": "Supprime définitivement un enregistrement de mémoire.",
        "memory_stats": "Retourne les statistiques de mémoire et les adresses MCP locales.",
        "server_info_memory": "Retourne les informations de base du serveur de mémoire et les adresses MCP locales.",
    },
    "it": {
        "memory_write": "Scrive un record di memoria.\nLunghezza massima del riepilogo: 1000 caratteri.\nLunghezza massima del contenuto: 100000 caratteri.\nLivello di importanza: 1-10.",
        "memory_search": "Cerca record di memoria con testo e filtri.\nNumero massimo di risultati: 1-50.",
        "memory_get_context": "Restituisce un contesto di memoria compatto corrispondente alla query.",
        "memory_update": "Aggiorna un record di memoria.\nLunghezza massima del riepilogo: 1000 caratteri.\nLunghezza massima del contenuto: 100000 caratteri.\nLivello di importanza: 1-10.",
        "memory_delete": "Elimina definitivamente un record di memoria.",
        "memory_stats": "Restituisce statistiche della memoria e indirizzi MCP locali.",
        "server_info_memory": "Restituisce le informazioni di base del server memoria e gli indirizzi MCP locali.",
    },
    "es": {
        "memory_write": "Escribe un registro de memoria.\nLongitud máxima del resumen: 1000 caracteres.\nLongitud máxima del contenido: 100000 caracteres.\nNivel de importancia: 1-10.",
        "memory_search": "Busca registros de memoria con texto y filtros.\nCantidad máxima de resultados: 1-50.",
        "memory_get_context": "Devuelve un contexto de memoria compacto que coincide con la consulta.",
        "memory_update": "Actualiza un registro de memoria.\nLongitud máxima del resumen: 1000 caracteres.\nLongitud máxima del contenido: 100000 caracteres.\nNivel de importancia: 1-10.",
        "memory_delete": "Elimina permanentemente un registro de memoria.",
        "memory_stats": "Devuelve estadísticas de memoria y direcciones MCP locales.",
        "server_info_memory": "Devuelve información básica del servidor de memoria y direcciones MCP locales.",
    },
}


def _tool_description(tool_name: str) -> str:
    language = TOOL_LANGUAGE if TOOL_LANGUAGE in SUPPORTED_TOOL_LANGUAGES else "en"
    return TOOL_DESCRIPTIONS[language][tool_name]



class MemoryWriteInput(BaseModel):
    scope: str = Field(default="global")
    kind: str
    title: str = Field(default="")
    summary: str = Field(description="Memory summary. Maximum length: 1000 characters.")
    content: str = Field(default="", description="Detailed memory content. Maximum length: 100000 characters.")
    tags: list[str] = Field(default_factory=list)
    importance: int = Field(default=5, ge=1, le=10)
    is_pinned: bool = False
    source: str = Field(default="user_command")
    metadata: dict[str, Any] = Field(default_factory=dict)


def utc_now() -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0)


def utc_now_iso() -> str:
    return utc_now().isoformat()


def _normalize_space(text: str) -> str:
    return re.sub(r"\s+", " ", (text or "").strip())


def _normalize_tags(tags: list[str] | None) -> list[str]:
    normalized: list[str] = []
    seen: set[str] = set()
    for raw in tags or []:
        tag = _normalize_space(str(raw)).lower()
        if not tag:
            continue
        tag = tag[:MAX_TAG_LENGTH]
        if tag not in seen:
            seen.add(tag)
            normalized.append(tag)
        if len(normalized) >= MAX_TAGS:
            break
    return normalized


def _normalize_scope(scope: str | None) -> str:
    value = _normalize_space(scope or "global").lower()
    return value or "global"


def _normalize_kind(kind: str | None) -> str:
    raw = _normalize_space(kind or "summary").lower()
    mapped = KIND_ALIASES.get(raw, raw)
    if mapped not in ALLOWED_KINDS:
        return "summary"
    return mapped or "summary"


def _normalize_status(status: str | None) -> str:
    return _normalize_space(status or "active").lower() or "active"


def _build_fts_query(query: str) -> str:
    tokens: list[str] = []
    seen: set[str] = set()
    for raw in re.findall(r"\w+", _normalize_space(query).lower(), flags=re.UNICODE):
        token = raw.strip("_")
        if not token or token in seen:
            continue
        seen.add(token)
        tokens.append(token)
        if len(tokens) >= 12:
            break
    return " AND ".join(f'"{token}"*' for token in tokens)


def _stable_hash(scope: str, kind: str, summary: str, content: str) -> str:
    raw = "\n".join([
        _normalize_scope(scope),
        _normalize_kind(kind),
        _normalize_space(summary).lower(),
        _normalize_space(content).lower(),
    ])
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def _detect_local_ip() -> str:
    with contextlib.suppress(Exception):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.connect(("8.8.8.8", 80))
        ip = sock.getsockname()[0]
        sock.close()
        if ipaddress.ip_address(ip).is_private:
            return ip
    return "127.0.0.1"


def _connect() -> sqlite3.Connection:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA synchronous=NORMAL;")
    conn.execute("PRAGMA foreign_keys=ON;")
    conn.execute("PRAGMA temp_store=MEMORY;")
    return conn


def _existing_columns(conn: sqlite3.Connection, table_name: str) -> set[str]:
    try:
        rows = conn.execute(f"PRAGMA table_info({table_name})").fetchall()
    except sqlite3.DatabaseError:
        return set()
    return {str(row[1]) for row in rows}


def _memory_item_count(conn: sqlite3.Connection) -> int:
    row = conn.execute("SELECT COUNT(*) AS count FROM memory_items").fetchone()
    return int(row["count"] if row is not None else 0)


def init_db() -> None:
    with DB_LOCK:
        conn = _connect()
        try:
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS memory_items (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    scope TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    title TEXT NOT NULL DEFAULT '',
                    summary TEXT NOT NULL,
                    content TEXT NOT NULL DEFAULT '',
                    tags_json TEXT NOT NULL DEFAULT '[]',
                    importance INTEGER NOT NULL DEFAULT 5,
                    status TEXT NOT NULL DEFAULT 'active',
                    is_pinned INTEGER NOT NULL DEFAULT 0,
                    source TEXT NOT NULL DEFAULT 'mcp',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    last_accessed_at TEXT,
                    access_count INTEGER NOT NULL DEFAULT 0,
                    dedupe_hash TEXT NOT NULL,
                    metadata_json TEXT NOT NULL DEFAULT '{}'
                );

                CREATE UNIQUE INDEX IF NOT EXISTS idx_memory_dedupe_active
                ON memory_items(dedupe_hash, status);

                CREATE INDEX IF NOT EXISTS idx_memory_scope_status
                ON memory_items(scope, status);

                CREATE INDEX IF NOT EXISTS idx_memory_kind_status
                ON memory_items(kind, status);

                CREATE INDEX IF NOT EXISTS idx_memory_importance
                ON memory_items(importance DESC, is_pinned DESC, updated_at DESC);

                CREATE INDEX IF NOT EXISTS idx_memory_created_at
                ON memory_items(created_at DESC);

                CREATE INDEX IF NOT EXISTS idx_memory_updated_at
                ON memory_items(updated_at DESC);
                """
            )

            fts_columns = _existing_columns(conn, "memory_items_fts")
            if fts_columns and "title" not in fts_columns:
                if _memory_item_count(conn) == 0:
                    conn.executescript(
                        """
                        DROP TRIGGER IF EXISTS memory_items_ai;
                        DROP TRIGGER IF EXISTS memory_items_ad;
                        DROP TRIGGER IF EXISTS memory_items_au;
                        DROP TABLE IF EXISTS memory_items_fts;
                        """
                    )
                else:
                    raise RuntimeError(
                        "Existing memory database uses an older FTS schema without title. "
                        "Back up or clear the database before installing this version."
                    )

            conn.executescript(
                """
                CREATE VIRTUAL TABLE IF NOT EXISTS memory_items_fts USING fts5(
                    title,
                    summary,
                    content,
                    tags,
                    content='memory_items',
                    content_rowid='id'
                );

                CREATE TRIGGER IF NOT EXISTS memory_items_ai AFTER INSERT ON memory_items BEGIN
                    INSERT INTO memory_items_fts(rowid, title, summary, content, tags)
                    VALUES (new.id, new.title, new.summary, new.content, new.tags_json);
                END;

                CREATE TRIGGER IF NOT EXISTS memory_items_ad AFTER DELETE ON memory_items BEGIN
                    INSERT INTO memory_items_fts(memory_items_fts, rowid, title, summary, content, tags)
                    VALUES('delete', old.id, old.title, old.summary, old.content, old.tags_json);
                END;

                CREATE TRIGGER IF NOT EXISTS memory_items_au AFTER UPDATE ON memory_items BEGIN
                    INSERT INTO memory_items_fts(memory_items_fts, rowid, title, summary, content, tags)
                    VALUES('delete', old.id, old.title, old.summary, old.content, old.tags_json);
                    INSERT INTO memory_items_fts(rowid, title, summary, content, tags)
                    VALUES (new.id, new.title, new.summary, new.content, new.tags_json);
                END;
                """
            )
            conn.commit()
        finally:
            conn.close()


def _utc_iso_to_local_display(value: str | None) -> str | None:
    if not value:
        return None
    parsed = datetime.fromisoformat(value)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(LOCAL_TIMEZONE).strftime(OUTPUT_LOCAL_DATETIME_FORMAT)


def _row_to_dict(row: sqlite3.Row) -> dict[str, Any]:
    item = {
        "id": row["id"],
        "scope": row["scope"],
        "kind": row["kind"],
        "title": row["title"],
        "summary": row["summary"],
        "content": row["content"],
        "tags": json.loads(row["tags_json"] or "[]"),
        "importance": row["importance"],
        "status": row["status"],
        "is_pinned": bool(row["is_pinned"]),
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
        "created_at_local": _utc_iso_to_local_display(row["created_at"]),
        "updated_at_local": _utc_iso_to_local_display(row["updated_at"]),
        "last_accessed_at": row["last_accessed_at"],
        "access_count": row["access_count"],
    }
    source = _normalize_space(row["source"] or "")
    if source and source != "user_command":
        item["source"] = source
    metadata = json.loads(row["metadata_json"] or "{}")
    if metadata:
        item["metadata"] = metadata
    return item


def _mark_access(conn: sqlite3.Connection, record_ids: list[int]) -> None:
    if not record_ids:
        return
    timestamp = utc_now_iso()
    placeholders = ",".join("?" for _ in record_ids)
    conn.execute(
        f"UPDATE memory_items SET last_accessed_at = ?, access_count = access_count + 1 WHERE id IN ({placeholders})",
        [timestamp, *record_ids],
    )


def _find_duplicate(conn: sqlite3.Connection, scope: str, kind: str, summary: str, content: str) -> sqlite3.Row | None:
    dedupe_hash = _stable_hash(scope, kind, summary, content)
    row = conn.execute(
        """
        SELECT *
        FROM memory_items
        WHERE dedupe_hash = ? AND status = 'active'
        ORDER BY is_pinned DESC, importance DESC, updated_at DESC
        LIMIT 1
        """,
        (dedupe_hash,),
    ).fetchone()
    return row


def _normalize_write_input(payload: MemoryWriteInput | dict[str, Any]) -> tuple[MemoryWriteInput, dict[str, Any]]:
    obj = payload if isinstance(payload, MemoryWriteInput) else MemoryWriteInput.model_validate(payload)
    normalized_kind = _normalize_kind(obj.kind)
    normalized = MemoryWriteInput(
        scope=_normalize_scope(obj.scope),
        kind=normalized_kind,
        title=_normalize_space(obj.title)[:MAX_TITLE_LENGTH],
        summary=_normalize_space(obj.summary)[:MAX_SUMMARY_LENGTH],
        content=_normalize_space(obj.content)[:MAX_CONTENT_LENGTH],
        tags=_normalize_tags(obj.tags),
        importance=max(1, min(int(obj.importance), 10)),
        is_pinned=bool(obj.is_pinned),
        source=_normalize_space(obj.source)[:80] or "user_command",
        metadata=obj.metadata or {},
    )
    info = {
        "requested_kind": _normalize_space(obj.kind).lower(),
        "normalized_kind": normalized_kind,
        "kind_changed": _normalize_space(obj.kind).lower() != normalized_kind,
    }
    return normalized, info


def _validate_write_input(data: MemoryWriteInput) -> list[str]:
    issues: list[str] = []
    if len(data.summary) < 8:
        issues.append("Summary is too short to be useful in long-term memory.")
    if len(data.summary) > MAX_SUMMARY_LENGTH:
        issues.append("Summary is too long. Maximum length is 1000 characters.")
    if len(data.content) > MAX_CONTENT_LENGTH:
        issues.append("Content is too long. Maximum length is 100000 characters.")
    return issues


def _insert_memory(conn: sqlite3.Connection, data: MemoryWriteInput) -> int:
    now = utc_now()
    cursor = conn.execute(
        """
        INSERT INTO memory_items (
            scope, kind, title, summary, content, tags_json, importance,
            status, is_pinned, source, created_at, updated_at,
            last_accessed_at, access_count, dedupe_hash, metadata_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, 'active', ?, ?, ?, ?, ?, 0, ?, ?)
        """,
        (
            data.scope,
            data.kind,
            data.title,
            data.summary,
            data.content,
            json.dumps(data.tags, ensure_ascii=False),
            data.importance,
            1 if data.is_pinned else 0,
            data.source,
            now.isoformat(),
            now.isoformat(),
            now.isoformat(),
            _stable_hash(data.scope, data.kind, data.summary, data.content),
            json.dumps(data.metadata, ensure_ascii=False),
        ),
    )
    return int(cursor.lastrowid)


def _parse_local_date_input(value: str | None, field_name: str) -> str | None:
    if value is None:
        return None
    normalized = _normalize_space(value)
    if not normalized:
        return None
    try:
        parsed = datetime.strptime(normalized, INPUT_DATE_FORMAT)
    except ValueError as exc:
        raise ValueError(f"{field_name} must use DD-MM-YYYY.") from exc
    return parsed.strftime(INPUT_DATE_FORMAT)


def _parse_local_datetime_input(value: str | None, field_name: str) -> tuple[str | None, str | None]:
    if value is None:
        return None, None
    normalized = _normalize_space(value)
    if not normalized:
        return None, None

    for fmt, message in (
        (INPUT_DATETIME_FORMAT, None),
        (INPUT_DATE_FORMAT, f"{normalized} 00:00:00"),
    ):
        try:
            parsed = datetime.strptime(normalized, fmt)
            local_dt = parsed.replace(tzinfo=LOCAL_TIMEZONE)
            display_value = message or normalized
            return local_dt.astimezone(timezone.utc).replace(microsecond=0).isoformat(), display_value
        except ValueError:
            continue

    raise ValueError(f"{field_name} must use DD-MM-YYYY or DD-MM-YYYY HH:MM:SS.")


def _apply_datetime_range(
    where_clauses: list[str],
    params: list[Any],
    column_name: str,
    exact_day: str | None,
    after_value: str | None,
    before_value: str | None,
) -> None:
    if exact_day:
        day_start_local = datetime.strptime(exact_day, INPUT_DATE_FORMAT).replace(tzinfo=LOCAL_TIMEZONE)
        day_end_local = day_start_local + timedelta(days=1)
        day_start_utc = day_start_local.astimezone(timezone.utc).replace(microsecond=0)
        day_end_utc = day_end_local.astimezone(timezone.utc).replace(microsecond=0)
        where_clauses.append(f"{column_name} >= ?")
        params.append(day_start_utc.isoformat())
        where_clauses.append(f"{column_name} < ?")
        params.append(day_end_utc.isoformat())

    if after_value:
        where_clauses.append(f"{column_name} >= ?")
        params.append(after_value)

    if before_value:
        where_clauses.append(f"{column_name} <= ?")
        params.append(before_value)


@mcp.tool(name="memory_write", description=_tool_description("memory_write"))
def memory_write(
    scope: str,
    kind: str,
    summary: str,
    title: str = "",
    content: str = "",
    tags: list[str] | None = None,
    importance: int = 5,
    is_pinned: bool = False,
    source: str = "user_command",
    metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Write one memory record.
    Summary maximum length: 1000 characters.
    Content maximum length: 100000 characters.
    Importance range: 1-10.
    """
    normalized, kind_info = _normalize_write_input(
        {
            "scope": scope,
            "kind": kind,
            "title": title,
            "summary": summary,
            "content": content,
            "tags": tags or [],
            "importance": importance,
            "is_pinned": is_pinned,
            "source": source,
            "metadata": metadata or {},
        }
    )
    validation_errors = _validate_write_input(normalized)
    if validation_errors:
        return {
            "status": "rejected",
            "reasons": validation_errors,
            "normalized_input": normalized.model_dump(),
            **kind_info,
        }

    with DB_LOCK:
        conn = _connect()
        try:
            duplicate = _find_duplicate(conn, normalized.scope, normalized.kind, normalized.summary, normalized.content)
            if duplicate is not None:
                return {
                    "status": "duplicate",
                    "memory_id": int(duplicate["id"]),
                    "message": "An equivalent active memory already exists.",
                    "normalized_input": normalized.model_dump(),
                    **kind_info,
                }
            memory_id = _insert_memory(conn, normalized)
            conn.commit()
            row = conn.execute("SELECT * FROM memory_items WHERE id = ?", (memory_id,)).fetchone()
            status = "written"
            if kind_info["kind_changed"]:
                status = "normalized_and_written"
            return {
                "status": status,
                "memory_id": memory_id,
                "memory": _row_to_dict(row),
                **kind_info,
            }
        finally:
            conn.close()


@mcp.tool(name="memory_search", description=_tool_description("memory_search"))
def memory_search(
    query: str = "",
    scope: str | None = None,
    kind: str | None = None,
    status: str = "active",
    tags: list[str] | None = None,
    min_importance: int | None = None,
    max_importance: int | None = None,
    days_back: int | None = None,
    created_on: str | None = None,
    created_after: str | None = None,
    created_before: str | None = None,
    updated_on: str | None = None,
    updated_after: str | None = None,
    updated_before: str | None = None,
    limit: int = DEFAULT_SEARCH_LIMIT,
) -> dict[str, Any]:
    """Search memory with text and filters."""
    safe_limit = max(1, min(int(limit), MAX_SEARCH_LIMIT))
    normalized_scope = _normalize_scope(scope) if scope else None
    normalized_kind = _normalize_kind(kind) if kind else None
    normalized_status = _normalize_status(status)
    normalized_tags = _normalize_tags(tags)
    normalized_query = _normalize_space(query)

    safe_min_importance = max(1, min(int(min_importance), 10)) if min_importance is not None else None
    safe_max_importance = max(1, min(int(max_importance), 10)) if max_importance is not None else None
    if safe_min_importance is not None and safe_max_importance is not None and safe_min_importance > safe_max_importance:
        safe_min_importance, safe_max_importance = safe_max_importance, safe_min_importance

    safe_days_back = None
    if days_back is not None:
        safe_days_back = max(1, int(days_back))

    try:
        parsed_created_on = _parse_local_date_input(created_on, "created_on")
        parsed_updated_on = _parse_local_date_input(updated_on, "updated_on")
        parsed_created_after, display_created_after = _parse_local_datetime_input(created_after, "created_after")
        parsed_created_before, display_created_before = _parse_local_datetime_input(created_before, "created_before")
        parsed_updated_after, display_updated_after = _parse_local_datetime_input(updated_after, "updated_after")
        parsed_updated_before, display_updated_before = _parse_local_datetime_input(updated_before, "updated_before")
    except ValueError as exc:
        return {"status": "invalid_filters", "message": str(exc)}

    with DB_LOCK:
        conn = _connect()
        try:
            params: list[Any] = []
            where_clauses = ["m.status = ?"]
            params.append(normalized_status)

            if normalized_scope:
                where_clauses.append("m.scope = ?")
                params.append(normalized_scope)
            if normalized_kind:
                where_clauses.append("m.kind = ?")
                params.append(normalized_kind)
            if normalized_tags:
                for tag in normalized_tags:
                    where_clauses.append("lower(m.tags_json) LIKE ?")
                    params.append(f'%"{tag}"%')
            if safe_min_importance is not None:
                where_clauses.append("m.importance >= ?")
                params.append(safe_min_importance)
            if safe_max_importance is not None:
                where_clauses.append("m.importance <= ?")
                params.append(safe_max_importance)
            if safe_days_back is not None:
                where_clauses.append("m.created_at >= ?")
                params.append((utc_now() - timedelta(days=safe_days_back)).isoformat())

            _apply_datetime_range(
                where_clauses,
                params,
                "m.created_at",
                parsed_created_on,
                parsed_created_after,
                parsed_created_before,
            )
            _apply_datetime_range(
                where_clauses,
                params,
                "m.updated_at",
                parsed_updated_on,
                parsed_updated_after,
                parsed_updated_before,
            )

            fts_query = _build_fts_query(normalized_query)
            if fts_query:
                sql = f"""
                    SELECT m.*, bm25(memory_items_fts, 2.0, 1.2, 0.6, 1.0) AS rank_score
                    FROM memory_items_fts
                    JOIN memory_items m ON m.id = memory_items_fts.rowid
                    WHERE {' AND '.join(where_clauses)}
                      AND memory_items_fts MATCH ?
                    ORDER BY m.is_pinned DESC, m.importance DESC, rank_score ASC, m.updated_at DESC
                    LIMIT ?
                """
                params.append(fts_query)
                params.append(safe_limit)
            else:
                sql = f"""
                    SELECT m.*, NULL AS rank_score
                    FROM memory_items m
                    WHERE {' AND '.join(where_clauses)}
                    ORDER BY m.is_pinned DESC, m.importance DESC, m.last_accessed_at DESC, m.updated_at DESC
                    LIMIT ?
                """
                params.append(safe_limit)

            rows = conn.execute(sql, params).fetchall()
            ids = [int(row["id"]) for row in rows]
            _mark_access(conn, ids)
            conn.commit()

            results = []
            for row in rows:
                item = _row_to_dict(row)
                item["rank_score"] = row["rank_score"]
                results.append(item)

            return {
                "status": "ok",
                "query": normalized_query,
                "scope": normalized_scope,
                "kind": normalized_kind,
                "status_filter": normalized_status,
                "tags": normalized_tags,
                "min_importance": safe_min_importance,
                "max_importance": safe_max_importance,
                "days_back": safe_days_back,
                "created_on": parsed_created_on,
                "created_after": display_created_after,
                "created_before": display_created_before,
                "updated_on": parsed_updated_on,
                "updated_after": display_updated_after,
                "updated_before": display_updated_before,
                "count": len(results),
                "results": results,
            }
        finally:
            conn.close()


@mcp.tool(name="memory_get_context", description=_tool_description("memory_get_context"))
def memory_get_context(
    query: str = "",
    scope: str | None = None,
    limit: int = DEFAULT_CONTEXT_LIMIT,
) -> dict[str, Any]:
    """Get a compact memory context."""
    result = memory_search(
        query=query,
        scope=scope,
        status="active",
        limit=max(1, min(int(limit), DEFAULT_CONTEXT_LIMIT * 2)),
    )
    trimmed = result["results"][: max(1, min(int(limit), DEFAULT_CONTEXT_LIMIT))]
    context_items = [
        {
            "id": item["id"],
            "scope": item["scope"],
            "kind": item["kind"],
            "title": item["title"],
            "summary": item["summary"],
            "content": item["content"],
            "tags": item["tags"],
            "importance": item["importance"],
            "is_pinned": item["is_pinned"],
        }
        for item in trimmed
    ]
    return {
        "query": query,
        "scope": scope,
        "count": len(context_items),
        "context": context_items,
    }


@mcp.tool(name="memory_update", description=_tool_description("memory_update"))
def memory_update(
    memory_id: int,
    title: str | None = None,
    summary: str | None = None,
    content: str | None = None,
    tags: list[str] | None = None,
    importance: int | None = None,
    is_pinned: bool | None = None,
    status: str | None = None,
    metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Update one memory record.
    Summary maximum length: 1000 characters.
    Content maximum length: 100000 characters.
    Importance range: 1-10.
    """
    with DB_LOCK:
        conn = _connect()
        try:
            row = conn.execute("SELECT * FROM memory_items WHERE id = ?", (memory_id,)).fetchone()
            if row is None:
                return {"status": "not_found", "memory_id": memory_id}

            new_title = _normalize_space(title)[:MAX_TITLE_LENGTH] if title is not None else row["title"]
            new_summary = _normalize_space(summary)[:MAX_SUMMARY_LENGTH] if summary is not None else row["summary"]
            new_content = _normalize_space(content)[:MAX_CONTENT_LENGTH] if content is not None else row["content"]
            new_tags = _normalize_tags(tags) if tags is not None else json.loads(row["tags_json"] or "[]")
            new_importance = max(1, min(int(importance), 10)) if importance is not None else row["importance"]
            new_pinned = 1 if (bool(is_pinned) if is_pinned is not None else bool(row["is_pinned"])) else 0
            new_status = _normalize_status(status) if status is not None else row["status"]
            new_metadata = metadata if metadata is not None else json.loads(row["metadata_json"] or "{}")
            new_hash = _stable_hash(row["scope"], row["kind"], new_summary, new_content)

            issues = []
            if len(new_summary) < 8:
                issues.append("Summary is too short to be useful in long-term memory.")
            if len(new_content) > MAX_CONTENT_LENGTH:
                issues.append("Content is too long. Maximum length is 100000 characters.")
            if issues:
                return {"status": "rejected", "memory_id": memory_id, "reasons": issues}

            conn.execute(
                """
                UPDATE memory_items
                SET title = ?,
                    summary = ?,
                    content = ?,
                    tags_json = ?,
                    importance = ?,
                    is_pinned = ?,
                    status = ?,
                    metadata_json = ?,
                    updated_at = ?,
                    dedupe_hash = ?
                WHERE id = ?
                """,
                (
                    new_title,
                    new_summary,
                    new_content,
                    json.dumps(new_tags, ensure_ascii=False),
                    new_importance,
                    new_pinned,
                    new_status,
                    json.dumps(new_metadata, ensure_ascii=False),
                    utc_now_iso(),
                    new_hash,
                    memory_id,
                ),
            )
            conn.commit()
            updated = conn.execute("SELECT * FROM memory_items WHERE id = ?", (memory_id,)).fetchone()
            return {"status": "updated", "memory": _row_to_dict(updated)}
        finally:
            conn.close()


@mcp.tool(name="memory_delete", description=_tool_description("memory_delete"))
def memory_delete(memory_id: int) -> dict[str, Any]:
    """Delete one memory record permanently."""
    with DB_LOCK:
        conn = _connect()
        try:
            row = conn.execute("SELECT * FROM memory_items WHERE id = ?", (memory_id,)).fetchone()
            if row is None:
                return {"status": "not_found", "memory_id": memory_id}
            conn.execute("DELETE FROM memory_items WHERE id = ?", (memory_id,))
            conn.commit()
            return {
                "status": "deleted",
                "memory_id": memory_id,
                "deleted_summary": row["summary"],
            }
        finally:
            conn.close()


@mcp.tool(name="memory_stats", description=_tool_description("memory_stats"))
def memory_stats() -> dict[str, Any]:
    """Get memory counts and endpoints."""
    local_ip = _detect_local_ip()
    with DB_LOCK:
        conn = _connect()
        try:
            totals = conn.execute(
                "SELECT status, COUNT(*) AS count FROM memory_items GROUP BY status ORDER BY status"
            ).fetchall()
            kinds = conn.execute(
                "SELECT kind, COUNT(*) AS count FROM memory_items WHERE status = 'active' GROUP BY kind ORDER BY count DESC, kind ASC"
            ).fetchall()
            pinned_count = conn.execute(
                "SELECT COUNT(*) AS count FROM memory_items WHERE status = 'active' AND is_pinned = 1"
            ).fetchone()["count"]
            total_count = conn.execute("SELECT COUNT(*) AS count FROM memory_items").fetchone()["count"]
        finally:
            conn.close()

    return {
        "project_name": PROJECT_NAME,
        "db_path": str(DB_PATH),
        "mcp_endpoint_local": f"http://127.0.0.1:{MCP_PORT}/mcp",
        "mcp_endpoint_lan": f"http://{local_ip}:{MCP_PORT}/mcp",
        "total_count": total_count,
        "active_pinned_count": pinned_count,
        "counts_by_status": {row["status"]: row["count"] for row in totals},
        "active_counts_by_kind": {row["kind"]: row["count"] for row in kinds},
    }


@mcp.tool(name="server_info_memory", description=_tool_description("server_info_memory"))
def server_info_memory() -> dict[str, Any]:
    """Get server paths and endpoints."""
    local_ip = _detect_local_ip()
    return {
        "project_name": PROJECT_NAME,
        "base_dir": str(BASE_DIR),
        "data_dir": str(DATA_DIR),
        "db_path": str(DB_PATH),
        "mcp_endpoint_local": f"http://127.0.0.1:{MCP_PORT}/mcp",
        "mcp_endpoint_lan": f"http://{local_ip}:{MCP_PORT}/mcp",
    }


@asynccontextmanager
async def lifespan(app: Starlette):
    init_db()
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
  printf '  ├── mcp_database/\n'
  printf '  │   └── memory_database.sqlite3\n'
  printf '  └── %s/\n' "${PROJECT_DIR_NAME}"
  printf '      ├── %s\n' "${ENV_FILE##*/}"
  printf '      ├── .venv/\n'
  printf '      └── app/\n'
  printf '          └── %s\n' "${SERVER_FILE_NAME}"

  printf '\nFull paths:\n'
  printf '  %-*s %s\n' "${path_label_width}" 'projects root directory:' "${ROOT_DIR}"
  printf '  %-*s %s\n' "${path_label_width}" 'project directory:' "${BASE_DIR}"
  printf '  %-*s %s\n' "${path_label_width}" 'application:' "${APP_DIR}"
  printf '  %-*s %s\n' "${path_label_width}" 'database directory:' "${DATA_DIR}"
  printf '  %-*s %s\n' "${path_label_width}" 'memory database:' "${DB_PATH}"
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
