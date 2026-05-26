#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_NAME="mcp_basic_contacts"
PROJECT_ROOT_DIR_NAME="mcp_server_tools"
PROJECT_DIR_NAME="mcp_basic_contacts"
SERVER_FILE_NAME="server.py"
SERVICE_NAME="mcp-basic-contacts.service"
DEFAULT_MCP_PORT="8004"
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
CONTACTS_DB_PATH="${DATA_DIR}/contacts_database.sqlite3"
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
CONTACTS_DB_PATH=${CONTACTS_DB_PATH}
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

import json
import os
import re
import socket
import sqlite3
import threading
import contextlib
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

from mcp.server.fastmcp import FastMCP
from pydantic import BaseModel, Field
from starlette.applications import Starlette
from starlette.middleware.cors import CORSMiddleware
from starlette.routing import Mount

PROJECT_NAME = os.environ.get("PROJECT_NAME", "mcp_basic_contacts")
DEFAULT_TIMEZONE = os.environ.get("DEFAULT_TIMEZONE", "UTC")
TOOL_LANGUAGE = os.environ.get("TOOL_LANGUAGE", "en").strip().lower()
BASE_DIR = Path(
    os.environ.get("BASE_DIR", str(Path.home() / "mcp_server_tools" / "mcp_basic_contacts"))
).resolve()
DATA_DIR = Path(os.environ.get("DATA_DIR", str(Path.home() / "mcp_server_tools" / "mcp_database"))).resolve()
CONTACTS_DB_PATH = Path(os.environ.get("CONTACTS_DB_PATH", str(DATA_DIR / "contacts_database.sqlite3"))).resolve()
MCP_PORT = int(os.environ.get("MCP_PORT", "8004"))

SUPPORTED_TOOL_LANGUAGES = {"pl", "en", "de", "fr", "it", "es"}

TOOL_DESCRIPTIONS = {
    "pl": {
        "contacts_create": "Tworzy kontakt w lokalnej bazie kontaktów.",
        "contacts_get": "Zwraca jeden kontakt według numerycznego ID kontaktu.",
        "contacts_list_recent": "Wyświetla ostatnio zaktualizowane kontakty.\nMaksymalna liczba wyników: 1-50.",
        "contacts_search": "Wyszukuje kontakty po nazwie, pseudonimie, e-mailu, telefonie, mieście, firmie, notatkach lub tagach.\nMaksymalna liczba wyników: 1-50.",
        "contacts_resolve_person": "Dopasowuje opis osoby do kontaktów i znanych adresów e-mail.",
        "contacts_resolve_recipient": "Dopasowuje odbiorcę do jednego głównego adresu e-mail, jeśli jest to możliwe.",
        "contacts_update": "Aktualizuje istniejący kontakt według numerycznego ID kontaktu.",
        "contacts_delete": "Usuwa kontakt według numerycznego ID kontaktu.",
        "contacts_exists": "Sprawdza, czy kontakt istnieje lub czy zapytanie jednoznacznie wskazuje jeden kontakt.",
        "server_info_contacts": "Zwraca podstawowe informacje o serwerze kontaktów, bazie danych i lokalnych adresach MCP.",
    },
    "en": {
        "contacts_create": "Creates a contact in the local contacts database.",
        "contacts_get": "Returns one contact by numeric contact ID.",
        "contacts_list_recent": "Lists the most recently updated contacts.\nResults maximum count: 1-50.",
        "contacts_search": "Searches contacts by name, nickname, email, phone, city, company, notes, or tags.\nResults maximum count: 1-50.",
        "contacts_resolve_person": "Resolves a person-like query into matching contacts and known email addresses.",
        "contacts_resolve_recipient": "Resolves a recipient identifier into one primary email address when possible.",
        "contacts_update": "Updates an existing contact by numeric contact ID.",
        "contacts_delete": "Deletes a contact by numeric contact ID.",
        "contacts_exists": "Checks whether a contact exists or whether the query resolves to one contact.",
        "server_info_contacts": "Returns basic contacts server information, database path, and local MCP endpoints.",
    },
    "de": {
        "contacts_create": "Erstellt einen Kontakt in der lokalen Kontaktdatenbank.",
        "contacts_get": "Gibt einen Kontakt anhand der numerischen Kontakt-ID zurück.",
        "contacts_list_recent": "Listet die zuletzt aktualisierten Kontakte auf.\nMaximale Ergebnisanzahl: 1-50.",
        "contacts_search": "Sucht Kontakte nach Name, Spitzname, E-Mail, Telefon, Stadt, Firma, Notizen oder Tags.\nMaximale Ergebnisanzahl: 1-50.",
        "contacts_resolve_person": "Löst eine personenähnliche Anfrage in passende Kontakte und bekannte E-Mail-Adressen auf.",
        "contacts_resolve_recipient": "Löst eine Empfängerangabe nach Möglichkeit in eine primäre E-Mail-Adresse auf.",
        "contacts_update": "Aktualisiert einen vorhandenen Kontakt anhand der numerischen Kontakt-ID.",
        "contacts_delete": "Löscht einen Kontakt anhand der numerischen Kontakt-ID.",
        "contacts_exists": "Prüft, ob ein Kontakt existiert oder ob die Anfrage eindeutig einen Kontakt ergibt.",
        "server_info_contacts": "Gibt grundlegende Informationen zum Kontaktserver, zur Datenbank und zu lokalen MCP-Adressen zurück.",
    },
    "fr": {
        "contacts_create": "Crée un contact dans la base de contacts locale.",
        "contacts_get": "Retourne un contact à partir de son ID numérique.",
        "contacts_list_recent": "Liste les contacts modifiés le plus récemment.\nNombre maximal de résultats : 1-50.",
        "contacts_search": "Recherche des contacts par nom, surnom, e-mail, téléphone, ville, entreprise, notes ou tags.\nNombre maximal de résultats : 1-50.",
        "contacts_resolve_person": "Résout une requête de type personne en contacts correspondants et adresses e-mail connues.",
        "contacts_resolve_recipient": "Résout un destinataire en une adresse e-mail principale lorsque c'est possible.",
        "contacts_update": "Met à jour un contact existant à partir de son ID numérique.",
        "contacts_delete": "Supprime un contact à partir de son ID numérique.",
        "contacts_exists": "Vérifie si un contact existe ou si la requête correspond clairement à un contact.",
        "server_info_contacts": "Retourne les informations de base du serveur de contacts, de la base de données et les adresses MCP locales.",
    },
    "it": {
        "contacts_create": "Crea un contatto nel database locale dei contatti.",
        "contacts_get": "Restituisce un contatto tramite ID numerico.",
        "contacts_list_recent": "Elenca i contatti aggiornati più di recente.\nNumero massimo di risultati: 1-50.",
        "contacts_search": "Cerca contatti per nome, soprannome, email, telefono, città, azienda, note o tag.\nNumero massimo di risultati: 1-50.",
        "contacts_resolve_person": "Risolve una richiesta riferita a una persona in contatti corrispondenti e indirizzi email noti.",
        "contacts_resolve_recipient": "Risolve un destinatario in un indirizzo email principale quando possibile.",
        "contacts_update": "Aggiorna un contatto esistente tramite ID numerico.",
        "contacts_delete": "Elimina un contatto tramite ID numerico.",
        "contacts_exists": "Verifica se un contatto esiste o se la richiesta identifica chiaramente un contatto.",
        "server_info_contacts": "Restituisce le informazioni di base del server contatti, del database e gli indirizzi MCP locali.",
    },
    "es": {
        "contacts_create": "Crea un contacto en la base de contactos local.",
        "contacts_get": "Devuelve un contacto por ID numérico.",
        "contacts_list_recent": "Lista los contactos actualizados más recientemente.\nCantidad máxima de resultados: 1-50.",
        "contacts_search": "Busca contactos por nombre, apodo, correo, teléfono, ciudad, empresa, notas o etiquetas.\nCantidad máxima de resultados: 1-50.",
        "contacts_resolve_person": "Resuelve una consulta de persona en contactos coincidentes y correos conocidos.",
        "contacts_resolve_recipient": "Resuelve un destinatario en un correo principal cuando es posible.",
        "contacts_update": "Actualiza un contacto existente por ID numérico.",
        "contacts_delete": "Elimina un contacto por ID numérico.",
        "contacts_exists": "Comprueba si un contacto existe o si la consulta identifica claramente un contacto.",
        "server_info_contacts": "Devuelve información básica del servidor de contactos, la base de datos y direcciones MCP locales.",
    },
}

try:
    LOCAL_TZ = ZoneInfo(DEFAULT_TIMEZONE)
except Exception:
    LOCAL_TZ = timezone.utc

CONTACTS_DB_LOCK = threading.Lock()

mcp = FastMCP(
    PROJECT_NAME,
    stateless_http=True,
    json_response=True,
    host="0.0.0.0",
)


def _tool_description(tool_name: str) -> str:
    language = TOOL_LANGUAGE if TOOL_LANGUAGE in SUPPORTED_TOOL_LANGUAGES else "en"
    return TOOL_DESCRIPTIONS[language][tool_name]


class RecentInput(BaseModel):
    limit: int = Field(default=10, ge=1, le=50, description="Maximum number of items to return.")


class ContactCreateInput(BaseModel):
    first_name: str = ""
    last_name: str = ""
    nickname: str = ""
    display_name: str = ""
    primary_email: str = ""
    secondary_email: str = ""
    phone_primary: str = ""
    phone_secondary: str = ""
    street: str = ""
    postal_code: str = ""
    city: str = ""
    country: str = ""
    company: str = ""
    job_title: str = ""
    notes: str = ""
    tags: list[str] = Field(default_factory=list)


class ContactSearchInput(BaseModel):
    query: str = Field(
        default="",
        description="Search contacts by nickname, first name, last name, display name, email, phone, city, company, notes, or tags.",
    )
    limit: int = Field(default=10, ge=1, le=50, description="Maximum number of contacts to return.")


class ContactGetInput(BaseModel):
    contact_id: int = Field(description="Numeric contact ID.")


class ContactUpdateInput(BaseModel):
    contact_id: int
    first_name: str | None = None
    last_name: str | None = None
    nickname: str | None = None
    display_name: str | None = None
    primary_email: str | None = None
    secondary_email: str | None = None
    phone_primary: str | None = None
    phone_secondary: str | None = None
    street: str | None = None
    postal_code: str | None = None
    city: str | None = None
    country: str | None = None
    company: str | None = None
    job_title: str | None = None
    notes: str | None = None
    tags: list[str] | None = None


class ContactDeleteInput(BaseModel):
    contact_id: int = Field(description="Numeric contact ID to delete.")


class ResolveRecipientInput(BaseModel):
    value: str = Field(
        description="Value to resolve, for example nickname, first name, last name, email, phone number, display name, or company."
    )


class ContactExistsInput(BaseModel):
    query: str = Field(description="Value used to check whether a contact exists or resolves uniquely.")


def _normalize_whitespace(value: str) -> str:
    return re.sub(r"\s+", " ", (value or "")).strip()


def _lower(value: str) -> str:
    return _normalize_whitespace(value).lower()


def _normalize_phone(value: str) -> str:
    return re.sub(r"\D+", "", value or "")


def _iso_local(dt: datetime | None) -> str:
    if dt is None:
        return ""
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(LOCAL_TZ).isoformat()


def _get_local_ip() -> str:
    ip = "127.0.0.1"
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.connect(("8.8.8.8", 80))
        ip = sock.getsockname()[0]
        sock.close()
    except Exception:
        pass
    return ip


def _looks_like_email(value: str) -> bool:
    return bool(re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", (value or "").strip()))


def _contact_db() -> sqlite3.Connection:
    conn = sqlite3.connect(CONTACTS_DB_PATH, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def _existing_columns(conn: sqlite3.Connection, table_name: str) -> set[str]:
    rows = conn.execute(f"PRAGMA table_info({table_name})").fetchall()
    return {str(row[1]) for row in rows}


def _safe_json_loads(raw: str) -> list[str]:
    try:
        value = json.loads(raw or "[]")
        if isinstance(value, list):
            return [str(item) for item in value]
    except Exception:
        pass
    return []


def _normalize_tags(tags: list[str]) -> list[str]:
    normalized: list[str] = []
    seen: set[str] = set()
    for tag in tags:
        clean = _normalize_whitespace(str(tag))
        if not clean:
            continue
        key = clean.lower()
        if key in seen:
            continue
        seen.add(key)
        normalized.append(clean)
    return normalized


def init_contacts_db() -> None:
    CONTACTS_DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    with CONTACTS_DB_LOCK:
        conn = _contact_db()
        try:
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS contacts (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    first_name TEXT NOT NULL DEFAULT '',
                    last_name TEXT NOT NULL DEFAULT '',
                    nickname TEXT NOT NULL DEFAULT '',
                    display_name TEXT NOT NULL DEFAULT '',
                    primary_email TEXT NOT NULL DEFAULT '',
                    secondary_email TEXT NOT NULL DEFAULT '',
                    phone_primary TEXT NOT NULL DEFAULT '',
                    phone_secondary TEXT NOT NULL DEFAULT '',
                    street TEXT NOT NULL DEFAULT '',
                    postal_code TEXT NOT NULL DEFAULT '',
                    city TEXT NOT NULL DEFAULT '',
                    country TEXT NOT NULL DEFAULT '',
                    company TEXT NOT NULL DEFAULT '',
                    job_title TEXT NOT NULL DEFAULT '',
                    notes TEXT NOT NULL DEFAULT '',
                    tags_json TEXT NOT NULL DEFAULT '[]',
                    normalized_name TEXT NOT NULL DEFAULT '',
                    normalized_nickname TEXT NOT NULL DEFAULT '',
                    normalized_display_name TEXT NOT NULL DEFAULT '',
                    normalized_email_primary TEXT NOT NULL DEFAULT '',
                    normalized_email_secondary TEXT NOT NULL DEFAULT '',
                    normalized_phone_primary TEXT NOT NULL DEFAULT '',
                    normalized_phone_secondary TEXT NOT NULL DEFAULT '',
                    normalized_city TEXT NOT NULL DEFAULT '',
                    normalized_company TEXT NOT NULL DEFAULT '',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                """
            )

            columns = _existing_columns(conn, "contacts")
            if "normalized_display_name" not in columns:
                conn.execute("ALTER TABLE contacts ADD COLUMN normalized_display_name TEXT NOT NULL DEFAULT ''")
            if "normalized_company" not in columns:
                conn.execute("ALTER TABLE contacts ADD COLUMN normalized_company TEXT NOT NULL DEFAULT ''")

            rows = conn.execute(
                "SELECT id, first_name, last_name, nickname, display_name, primary_email, secondary_email, phone_primary, phone_secondary, city, company FROM contacts"
            ).fetchall()
            for row in rows:
                first_name = _normalize_whitespace(row["first_name"])
                last_name = _normalize_whitespace(row["last_name"])
                nickname = _normalize_whitespace(row["nickname"])
                display_name = _normalize_whitespace(row["display_name"])
                if not display_name:
                    display_name = _normalize_whitespace(f"{first_name} {last_name}") or nickname
                conn.execute(
                    """
                    UPDATE contacts SET
                        normalized_name = ?,
                        normalized_nickname = ?,
                        normalized_display_name = ?,
                        normalized_email_primary = ?,
                        normalized_email_secondary = ?,
                        normalized_phone_primary = ?,
                        normalized_phone_secondary = ?,
                        normalized_city = ?,
                        normalized_company = ?
                    WHERE id = ?
                    """,
                    [
                        _lower(f"{first_name} {last_name} {display_name}"),
                        _lower(nickname),
                        _lower(display_name),
                        _lower(row["primary_email"]),
                        _lower(row["secondary_email"]),
                        _normalize_phone(row["phone_primary"]),
                        _normalize_phone(row["phone_secondary"]),
                        _lower(row["city"]),
                        _lower(row["company"]),
                        row["id"],
                    ],
                )

            conn.executescript(
                """
                CREATE INDEX IF NOT EXISTS idx_contacts_nickname ON contacts(normalized_nickname);
                CREATE INDEX IF NOT EXISTS idx_contacts_display_name ON contacts(normalized_display_name);
                CREATE INDEX IF NOT EXISTS idx_contacts_email1 ON contacts(normalized_email_primary);
                CREATE INDEX IF NOT EXISTS idx_contacts_email2 ON contacts(normalized_email_secondary);
                CREATE INDEX IF NOT EXISTS idx_contacts_phone1 ON contacts(normalized_phone_primary);
                CREATE INDEX IF NOT EXISTS idx_contacts_phone2 ON contacts(normalized_phone_secondary);
                CREATE INDEX IF NOT EXISTS idx_contacts_name ON contacts(normalized_name);
                CREATE INDEX IF NOT EXISTS idx_contacts_city ON contacts(normalized_city);
                CREATE INDEX IF NOT EXISTS idx_contacts_company ON contacts(normalized_company);
                """
            )
            conn.commit()
        finally:
            conn.close()


def _contact_row_to_dict(row: sqlite3.Row | None) -> dict[str, Any] | None:
    if row is None:
        return None
    return {
        "id": row["id"],
        "first_name": row["first_name"],
        "last_name": row["last_name"],
        "nickname": row["nickname"],
        "display_name": row["display_name"],
        "primary_email": row["primary_email"],
        "secondary_email": row["secondary_email"],
        "phone_primary": row["phone_primary"],
        "phone_secondary": row["phone_secondary"],
        "street": row["street"],
        "postal_code": row["postal_code"],
        "city": row["city"],
        "country": row["country"],
        "company": row["company"],
        "job_title": row["job_title"],
        "notes": row["notes"],
        "tags": _safe_json_loads(row["tags_json"]),
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
    }


def _validate_contact_create(inp: ContactCreateInput) -> None:
    first_name = _normalize_whitespace(inp.first_name)
    last_name = _normalize_whitespace(inp.last_name)
    nickname = _normalize_whitespace(inp.nickname)
    primary_email = _normalize_whitespace(inp.primary_email)
    secondary_email = _normalize_whitespace(inp.secondary_email)
    phone_primary = _normalize_whitespace(inp.phone_primary)
    phone_secondary = _normalize_whitespace(inp.phone_secondary)
    street = _normalize_whitespace(inp.street)

    has_full_name = bool(first_name) and bool(last_name)
    has_nickname = bool(nickname)
    has_email = bool(primary_email) or bool(secondary_email)
    has_phone = bool(phone_primary) or bool(phone_secondary)
    has_street = bool(street)

    if not (has_full_name or has_nickname):
        raise ValueError("Contact must include first_name and last_name, or nickname.")

    if not (has_email or has_phone or has_street):
        raise ValueError("Contact must include at least one email, phone number, or street address.")



def _merge_contact_update(existing: dict[str, Any], inp: ContactUpdateInput) -> ContactCreateInput:
    payload = {
        "first_name": existing["first_name"],
        "last_name": existing["last_name"],
        "nickname": existing["nickname"],
        "display_name": existing["display_name"],
        "primary_email": existing["primary_email"],
        "secondary_email": existing["secondary_email"],
        "phone_primary": existing["phone_primary"],
        "phone_secondary": existing["phone_secondary"],
        "street": existing["street"],
        "postal_code": existing["postal_code"],
        "city": existing["city"],
        "country": existing["country"],
        "company": existing["company"],
        "job_title": existing["job_title"],
        "notes": existing["notes"],
        "tags": existing["tags"],
    }

    updates = inp.model_dump(exclude_unset=True, exclude={"contact_id"})
    for key, value in updates.items():
        if value is not None:
            payload[key] = value

    merged = ContactCreateInput(**payload)
    _validate_contact_create(merged)
    return merged


def _contact_values(inp: ContactCreateInput | ContactUpdateInput) -> dict[str, str]:
    first_name = _normalize_whitespace(inp.first_name)
    last_name = _normalize_whitespace(inp.last_name)
    nickname = _normalize_whitespace(inp.nickname)
    display_name = _normalize_whitespace(inp.display_name)
    if not display_name:
        display_name = _normalize_whitespace(f"{first_name} {last_name}") or nickname

    tags = _normalize_tags(inp.tags)

    return {
        "first_name": first_name,
        "last_name": last_name,
        "nickname": nickname,
        "display_name": display_name,
        "primary_email": _normalize_whitespace(inp.primary_email),
        "secondary_email": _normalize_whitespace(inp.secondary_email),
        "phone_primary": _normalize_whitespace(inp.phone_primary),
        "phone_secondary": _normalize_whitespace(inp.phone_secondary),
        "street": _normalize_whitespace(inp.street),
        "postal_code": _normalize_whitespace(inp.postal_code),
        "city": _normalize_whitespace(inp.city),
        "country": _normalize_whitespace(inp.country),
        "company": _normalize_whitespace(inp.company),
        "job_title": _normalize_whitespace(inp.job_title),
        "notes": _normalize_whitespace(inp.notes),
        "tags_json": json.dumps(tags, ensure_ascii=False),
        "normalized_name": _lower(f"{first_name} {last_name} {display_name}"),
        "normalized_nickname": _lower(nickname),
        "normalized_display_name": _lower(display_name),
        "normalized_email_primary": _lower(inp.primary_email),
        "normalized_email_secondary": _lower(inp.secondary_email),
        "normalized_phone_primary": _normalize_phone(inp.phone_primary),
        "normalized_phone_secondary": _normalize_phone(inp.phone_secondary),
        "normalized_city": _lower(inp.city),
        "normalized_company": _lower(inp.company),
    }


def _match_score(contact: dict[str, Any], query: str) -> int:
    q = _lower(query)
    qp = _normalize_phone(query)
    score = 100

    if not q and not qp:
        return score

    if q:
        if q == _lower(contact.get("primary_email", "")):
            return 1
        if q == _lower(contact.get("secondary_email", "")):
            return 2
        if q == _lower(contact.get("nickname", "")):
            return 5
        if q == _lower(contact.get("display_name", "")):
            return 6
        full_name = _lower(f"{contact.get('first_name', '')} {contact.get('last_name', '')} {contact.get('display_name', '')}")
        if q == full_name:
            return 7

    if qp:
        if qp == _normalize_phone(contact.get("phone_primary", "")):
            return 3
        if qp == _normalize_phone(contact.get("phone_secondary", "")):
            return 4

    return score


def _resolve_contacts(query: str, limit: int = 10) -> list[dict[str, Any]]:
    q = _lower(query)
    qp = _normalize_phone(query)
    text_like = f"%{q}%"
    phone_like = f"%{qp}%" if qp else ""

    with CONTACTS_DB_LOCK:
        conn = _contact_db()
        try:
            if not q and not qp:
                rows = conn.execute("SELECT * FROM contacts ORDER BY updated_at DESC LIMIT ?", [limit]).fetchall()
            else:
                rows = conn.execute(
                    """
                    SELECT * FROM contacts
                    WHERE normalized_name LIKE ?
                       OR normalized_nickname LIKE ?
                       OR normalized_display_name LIKE ?
                       OR normalized_email_primary LIKE ?
                       OR normalized_email_secondary LIKE ?
                       OR normalized_phone_primary LIKE ?
                       OR normalized_phone_secondary LIKE ?
                       OR normalized_city LIKE ?
                       OR normalized_company LIKE ?
                       OR lower(notes) LIKE ?
                       OR lower(tags_json) LIKE ?
                    ORDER BY updated_at DESC
                    LIMIT ?
                    """,
                    [
                        text_like,
                        text_like,
                        text_like,
                        text_like,
                        text_like,
                        phone_like,
                        phone_like,
                        text_like,
                        text_like,
                        text_like,
                        text_like,
                        limit,
                    ],
                ).fetchall()
            contacts = [_contact_row_to_dict(r) for r in rows]
        finally:
            conn.close()

    contacts = [c for c in contacts if c is not None]
    contacts.sort(key=lambda c: (_match_score(c, query), c.get("updated_at", "")), reverse=False)
    return contacts[:limit]


@mcp.tool(description=_tool_description("contacts_create"))
def contacts_create(input: ContactCreateInput) -> dict[str, Any]:
    _validate_contact_create(input)
    vals = _contact_values(input)
    now = _iso_local(datetime.now(timezone.utc)) or ""
    with CONTACTS_DB_LOCK:
        conn = _contact_db()
        try:
            cur = conn.execute(
                """
                INSERT INTO contacts (
                    first_name, last_name, nickname, display_name,
                    primary_email, secondary_email, phone_primary, phone_secondary,
                    street, postal_code, city, country, company, job_title, notes, tags_json,
                    normalized_name, normalized_nickname, normalized_display_name,
                    normalized_email_primary, normalized_email_secondary,
                    normalized_phone_primary, normalized_phone_secondary,
                    normalized_city, normalized_company,
                    created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    vals["first_name"], vals["last_name"], vals["nickname"], vals["display_name"],
                    vals["primary_email"], vals["secondary_email"], vals["phone_primary"], vals["phone_secondary"],
                    vals["street"], vals["postal_code"], vals["city"], vals["country"], vals["company"], vals["job_title"], vals["notes"], vals["tags_json"],
                    vals["normalized_name"], vals["normalized_nickname"], vals["normalized_display_name"],
                    vals["normalized_email_primary"], vals["normalized_email_secondary"],
                    vals["normalized_phone_primary"], vals["normalized_phone_secondary"],
                    vals["normalized_city"], vals["normalized_company"],
                    now, now,
                ],
            )
            conn.commit()
            return {"status": "created", "contact_id": cur.lastrowid}
        finally:
            conn.close()


@mcp.tool(description=_tool_description("contacts_get"))
def contacts_get(input: ContactGetInput) -> dict[str, Any]:
    with CONTACTS_DB_LOCK:
        conn = _contact_db()
        try:
            row = conn.execute("SELECT * FROM contacts WHERE id = ?", [input.contact_id]).fetchone()
            return {"contact": _contact_row_to_dict(row)}
        finally:
            conn.close()


@mcp.tool(description=_tool_description("contacts_list_recent"))
def contacts_list_recent(input: RecentInput) -> dict[str, Any]:
    with CONTACTS_DB_LOCK:
        conn = _contact_db()
        try:
            rows = conn.execute("SELECT * FROM contacts ORDER BY updated_at DESC LIMIT ?", [input.limit]).fetchall()
            contacts = [_contact_row_to_dict(r) for r in rows]
            return {"count": len(contacts), "contacts": contacts}
        finally:
            conn.close()


@mcp.tool(description=_tool_description("contacts_search"))
def contacts_search(input: ContactSearchInput) -> dict[str, Any]:
    rows = _resolve_contacts(input.query, input.limit)
    return {"count": len(rows), "contacts": rows}


@mcp.tool(description=_tool_description("contacts_resolve_person"))
def contacts_resolve_person(input: ResolveRecipientInput) -> dict[str, Any]:
    rows = _resolve_contacts(input.value, 10)
    resolved = []
    for row in rows:
        emails = [e for e in [row.get("primary_email"), row.get("secondary_email")] if e]
        resolved.append({"contact": row, "emails": emails})
    return {"count": len(resolved), "matches": resolved}


@mcp.tool(description=_tool_description("contacts_resolve_recipient"))
def contacts_resolve_recipient(input: ResolveRecipientInput) -> dict[str, Any]:
    rows = _resolve_contacts(input.value, 10)
    candidates = [r for r in rows if r.get("primary_email")]
    if len(candidates) == 1:
        return {"status": "resolved", "contact": candidates[0], "email": candidates[0]["primary_email"]}
    return {"status": "ambiguous" if rows else "not_found", "matches": rows}


@mcp.tool(description=_tool_description("contacts_update"))
def contacts_update(input: ContactUpdateInput) -> dict[str, Any]:
    now = _iso_local(datetime.now(timezone.utc)) or ""
    with CONTACTS_DB_LOCK:
        conn = _contact_db()
        try:
            row = conn.execute("SELECT * FROM contacts WHERE id = ?", [input.contact_id]).fetchone()
            existing = _contact_row_to_dict(row)
            if existing is None:
                return {"status": "not_found", "contact_id": input.contact_id}

            merged = _merge_contact_update(existing, input)
            vals = _contact_values(merged)

            conn.execute(
                """
                UPDATE contacts SET
                    first_name=?, last_name=?, nickname=?, display_name=?,
                    primary_email=?, secondary_email=?, phone_primary=?, phone_secondary=?,
                    street=?, postal_code=?, city=?, country=?, company=?, job_title=?, notes=?, tags_json=?,
                    normalized_name=?, normalized_nickname=?, normalized_display_name=?,
                    normalized_email_primary=?, normalized_email_secondary=?,
                    normalized_phone_primary=?, normalized_phone_secondary=?,
                    normalized_city=?, normalized_company=?, updated_at=?
                WHERE id=?
                """,
                [
                    vals["first_name"], vals["last_name"], vals["nickname"], vals["display_name"],
                    vals["primary_email"], vals["secondary_email"], vals["phone_primary"], vals["phone_secondary"],
                    vals["street"], vals["postal_code"], vals["city"], vals["country"], vals["company"], vals["job_title"], vals["notes"], vals["tags_json"],
                    vals["normalized_name"], vals["normalized_nickname"], vals["normalized_display_name"],
                    vals["normalized_email_primary"], vals["normalized_email_secondary"],
                    vals["normalized_phone_primary"], vals["normalized_phone_secondary"],
                    vals["normalized_city"], vals["normalized_company"], now,
                    input.contact_id,
                ],
            )
            conn.commit()
            return {"status": "updated", "contact_id": input.contact_id}
        finally:
            conn.close()


@mcp.tool(description=_tool_description("contacts_delete"))
def contacts_delete(input: ContactDeleteInput) -> dict[str, Any]:
    with CONTACTS_DB_LOCK:
        conn = _contact_db()
        try:
            conn.execute("DELETE FROM contacts WHERE id = ?", [input.contact_id])
            conn.commit()
            return {"status": "deleted", "contact_id": input.contact_id}
        finally:
            conn.close()


@mcp.tool(description=_tool_description("contacts_exists"))
def contacts_exists(input: ContactExistsInput) -> dict[str, Any]:
    rows = _resolve_contacts(input.query, 10)
    if not rows:
        return {"status": "not_found", "count": 0, "matches": []}
    if len(rows) == 1:
        return {"status": "exists", "count": 1, "contact_id": rows[0]["id"], "contact": rows[0]}
    return {"status": "ambiguous", "count": len(rows), "matches": rows}


@mcp.tool(description=_tool_description("server_info_contacts"))
def server_info_contacts() -> dict[str, Any]:
    local_ip = _get_local_ip()
    with CONTACTS_DB_LOCK:
        conn = _contact_db()
        try:
            contacts_count = conn.execute("SELECT COUNT(*) FROM contacts").fetchone()[0]
        finally:
            conn.close()
    return {
        "project_name": PROJECT_NAME,
        "base_dir": str(BASE_DIR),
        "contacts_db_path": str(CONTACTS_DB_PATH),
        "mcp_endpoint_local": f"http://127.0.0.1:{MCP_PORT}/mcp",
        "mcp_endpoint_lan": f"http://{local_ip}:{MCP_PORT}/mcp",
        "timezone": DEFAULT_TIMEZONE,
        "tool_language": TOOL_LANGUAGE if TOOL_LANGUAGE in SUPPORTED_TOOL_LANGUAGES else "en",
        "contacts_count": contacts_count,
        "mode": "contacts_only",
        "tools": [
            "contacts_create",
            "contacts_get",
            "contacts_list_recent",
            "contacts_search",
            "contacts_resolve_person",
            "contacts_resolve_recipient",
            "contacts_update",
            "contacts_delete",
            "contacts_exists",
            "server_info_contacts",
        ],
    }


@contextlib.asynccontextmanager
async def lifespan(app: Starlette):
    init_contacts_db()
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
  printf '  │   └── contacts_database.sqlite3\n'
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
  printf '  %-*s %s\n' "${path_label_width}" 'contacts database:' "${CONTACTS_DB_PATH}"
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
