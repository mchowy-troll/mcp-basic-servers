#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_NAME="mcp_basic_files"
PROJECT_ROOT_DIR_NAME="mcp_server_tools"
PROJECT_DIR_NAME="mcp_basic_files"
SERVER_FILE_NAME="server.py"
SERVICE_NAME="mcp-basic-files.service"
DEFAULT_MCP_PORT="8002"
FALLBACK_TIMEZONE="UTC"
PYTHON_BIN="python3"
ENV_FILE_NAME=".env"

USER_NAME="${SUDO_USER:-$(whoami)}"
USER_HOME="$(getent passwd "${USER_NAME}" | cut -d: -f6)"
ROOT_DIR="${USER_HOME}/${PROJECT_ROOT_DIR_NAME}"
BASE_DIR="${ROOT_DIR}/${PROJECT_DIR_NAME}"
APP_DIR="${BASE_DIR}/app"
WORKSPACE_DIR="${ROOT_DIR}/mcp_workspace"
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
        curl ca-certificates python uv tzdata cairo pango gdk-pixbuf2 adwaita-fonts inter-font noto-fonts
      ;;
    ubuntu)
      log "Installing system packages with apt"
      sudo apt-get update
      sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        curl ca-certificates python3 python3-venv python3-pip tzdata \
        libcairo2 libpango-1.0-0 libpangoft2-1.0-0 libgdk-pixbuf-2.0-0 libffi-dev shared-mime-info \
        fonts-dejavu-core fonts-noto-core
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
  log "Creating application and workspace directories"
  mkdir -p \
    "${APP_DIR}" \
    "${WORKSPACE_DIR}"
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
WORKSPACE_DIR=${WORKSPACE_DIR}
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
    mcp starlette uvicorn pypdf weasyprint markdown latex2mathml
}

write_python_server() {
  log "Writing MCP server Python file"
  cat > "${APP_DIR}/${SERVER_FILE_NAME}" <<'PY'
from __future__ import annotations

import contextlib
import csv
import html
import ipaddress
import io
import os
import re
import socket
from datetime import datetime
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

import markdown as markdown_lib
from latex2mathml.converter import convert as latex_to_mathml
from mcp.server.fastmcp import FastMCP
from pypdf import PdfReader
from starlette.applications import Starlette
from starlette.middleware.cors import CORSMiddleware
from starlette.routing import Mount
from weasyprint import HTML

PROJECT_NAME = os.environ.get("PROJECT_NAME", "mcp_basic_files")
DEFAULT_TIMEZONE = os.environ.get("DEFAULT_TIMEZONE", "UTC")
TOOL_LANGUAGE = os.environ.get("TOOL_LANGUAGE", "en").strip().lower()
MCP_PORT = int(os.environ.get("MCP_PORT", "8002"))
BASE_DIR = Path(os.environ.get("BASE_DIR", str(Path.home() / "mcp_server_tools" / "mcp_basic_files"))).resolve()
WORKSPACE_DIR = Path(os.environ.get("WORKSPACE_DIR", str(Path.home() / "mcp_server_tools" / "mcp_workspace"))).resolve()

SUPPORTED_TOOL_LANGUAGES = {"pl", "en", "de", "fr", "it", "es"}

TOOL_DESCRIPTIONS = {
    "pl": {
        "file_datetime": "Zwraca aktualną datę i godzinę dla wybranej strefy czasowej.",
        "txt_read": "Czyta plik tekstowy z workspace.\nMaksymalna długość treści: 1-200000 znaków.",
        "txt_save": "Zapisuje plik tekstowy w workspace.",
        "csv_read": "Czyta plik CSV z workspace.\nMaksymalna długość treści: 1-10000 wierszy.",
        "csv_save": "Zapisuje plik CSV w workspace.",
        "markdown_save": "Zapisuje plik Markdown w workspace.",
        "pdf_save": "Tworzy plik PDF z treści Markdown.\nMaksymalna długość wygenerowanego PDF: 200 stron.",
        "server_info_files": "Zwraca podstawowe informacje o serwerze plików i lokalne adresy MCP.",
    },
    "en": {
        "file_datetime": "Returns current date and time for the selected timezone.",
        "txt_read": "Reads a text file from the workspace.\nContent maximum length: 1-200000 characters.",
        "txt_save": "Saves a text file inside the workspace.",
        "csv_read": "Reads a CSV file from the workspace.\nContent maximum length: 1-10000 rows.",
        "csv_save": "Saves a CSV file inside the workspace.",
        "markdown_save": "Saves a Markdown file inside the workspace.",
        "pdf_save": "Generates a PDF file from Markdown content.\nGenerated PDF maximum length: 200 pages.",
        "server_info_files": "Returns basic files server information and local MCP endpoints.",
    },
    "de": {
        "file_datetime": "Gibt das aktuelle Datum und die aktuelle Uhrzeit für die gewählte Zeitzone zurück.",
        "txt_read": "Liest eine Textdatei aus dem Workspace.\nMaximale Inhaltslänge: 1-200000 Zeichen.",
        "txt_save": "Speichert eine Textdatei im Workspace.",
        "csv_read": "Liest eine CSV-Datei aus dem Workspace.\nMaximale Inhaltslänge: 1-10000 Zeilen.",
        "csv_save": "Speichert eine CSV-Datei im Workspace.",
        "markdown_save": "Speichert eine Markdown-Datei im Workspace.",
        "pdf_save": "Erstellt eine PDF-Datei aus Markdown-Inhalt.\nMaximale Länge der erstellten PDF-Datei: 200 Seiten.",
        "server_info_files": "Gibt grundlegende Informationen zum Dateiserver und lokale MCP-Adressen zurück.",
    },
    "fr": {
        "file_datetime": "Retourne la date et l'heure actuelles pour le fuseau horaire choisi.",
        "txt_read": "Lit un fichier texte depuis le workspace.\nLongueur maximale du contenu : 1-200000 caractères.",
        "txt_save": "Enregistre un fichier texte dans le workspace.",
        "csv_read": "Lit un fichier CSV depuis le workspace.\nLongueur maximale du contenu : 1-10000 lignes.",
        "csv_save": "Enregistre un fichier CSV dans le workspace.",
        "markdown_save": "Enregistre un fichier Markdown dans le workspace.",
        "pdf_save": "Génère un fichier PDF à partir de contenu Markdown.\nLongueur maximale du PDF généré : 200 pages.",
        "server_info_files": "Retourne les informations de base du serveur de fichiers et les adresses MCP locales.",
    },
    "it": {
        "file_datetime": "Restituisce la data e l'ora attuali per il fuso orario scelto.",
        "txt_read": "Legge un file di testo dal workspace.\nLunghezza massima del contenuto: 1-200000 caratteri.",
        "txt_save": "Salva un file di testo nel workspace.",
        "csv_read": "Legge un file CSV dal workspace.\nLunghezza massima del contenuto: 1-10000 righe.",
        "csv_save": "Salva un file CSV nel workspace.",
        "markdown_save": "Salva un file Markdown nel workspace.",
        "pdf_save": "Genera un file PDF da contenuto Markdown.\nLunghezza massima del PDF generato: 200 pagine.",
        "server_info_files": "Restituisce le informazioni di base del server file e gli indirizzi MCP locali.",
    },
    "es": {
        "file_datetime": "Devuelve la fecha y hora actuales para la zona horaria elegida.",
        "txt_read": "Lee un archivo de texto desde el workspace.\nLongitud máxima del contenido: 1-200000 caracteres.",
        "txt_save": "Guarda un archivo de texto dentro del workspace.",
        "csv_read": "Lee un archivo CSV desde el workspace.\nLongitud máxima del contenido: 1-10000 filas.",
        "csv_save": "Guarda un archivo CSV dentro del workspace.",
        "markdown_save": "Guarda un archivo Markdown dentro del workspace.",
        "pdf_save": "Genera un archivo PDF a partir de contenido Markdown.\nLongitud máxima del PDF generado: 200 páginas.",
        "server_info_files": "Devuelve información básica del servidor de archivos y direcciones MCP locales.",
    },
}

MAX_TEXT_FILE_CHARS = 200_000
MAX_PDF_PAGES = 200
MAX_CSV_ROWS = 10_000
MAX_CSV_COLUMNS = 200
PDF_ALLOWED_ORIENTATIONS = {"portrait", "landscape"}

mcp = FastMCP(
    PROJECT_NAME,
    stateless_http=True,
    json_response=True,
    host="0.0.0.0",
)


def _tool_description(tool_name: str) -> str:
    language = TOOL_LANGUAGE if TOOL_LANGUAGE in SUPPORTED_TOOL_LANGUAGES else "en"
    return TOOL_DESCRIPTIONS[language][tool_name]


def _resolve_workspace_path(path: str) -> Path:
    filename = (path or "").strip()
    if not filename:
        raise ValueError("Path must not be empty.")
    if Path(filename).is_absolute():
        raise ValueError("Absolute paths are not allowed.")
    if filename in {".", ".."}:
        raise ValueError("Path must point to a file name.")
    if "/" in filename or "\\" in filename:
        raise ValueError("Subdirectories are not allowed.")

    candidate = (WORKSPACE_DIR / filename).resolve()
    if candidate.parent != WORKSPACE_DIR:
        raise ValueError("Access denied. Path must stay inside workspace.")
    return candidate


def _read_text_file(path: Path, *, max_chars: int | None = None) -> str:
    with open(path, "r", encoding="utf-8") as handle:
        content = handle.read()
    return content if max_chars is None else content[:max_chars]


def _write_text_file(path: Path, content: str) -> None:
    with open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write(content)


def _normalize_orientation(value: str) -> str:
    orientation = (value or "portrait").strip().lower()
    if orientation not in PDF_ALLOWED_ORIENTATIONS:
        allowed = ", ".join(sorted(PDF_ALLOWED_ORIENTATIONS))
        raise ValueError(f"Invalid page_orientation. Allowed values: {allowed}.")
    return orientation


def _strip_first_h1(markdown_text: str) -> tuple[str, str]:
    normalized = markdown_text.lstrip()
    match = re.match(r"^#\s+(.+?)\s*$", normalized, flags=re.MULTILINE)
    if not match:
        return "", markdown_text
    title = match.group(1).strip()
    stripped = re.sub(r"^#\s+.+?\n+", "", normalized, count=1, flags=re.MULTILINE)
    return title, stripped


def _latex_fragment_to_mathml(expr: str, display: str) -> str:
    mathml = latex_to_mathml(expr)
    if display == "block":
        return f'<div class="math math-block">{mathml}</div>'
    return f'<span class="math math-inline">{mathml}</span>'


def _replace_markdown_math(text: str) -> str:
    code_map: dict[str, str] = {}

    def stash(match: re.Match[str]) -> str:
        key = f"@@CODEBLOCK{len(code_map)}@@"
        code_map[key] = match.group(0)
        return key

    text = re.sub(r"```.*?```", stash, text, flags=re.DOTALL)
    text = re.sub(r"`[^`\n]+`", stash, text)

    text = re.sub(
        r"(?<!\\)\$\$(.+?)(?<!\\)\$\$",
        lambda m: "\n\n" + _latex_fragment_to_mathml(m.group(1).strip(), "block") + "\n\n",
        text,
        flags=re.DOTALL,
    )
    text = re.sub(
        r"(?<!\\)\$(.+?)(?<!\\)\$",
        lambda m: _latex_fragment_to_mathml(m.group(1).strip(), "inline"),
        text,
        flags=re.DOTALL,
    )

    for key, value in code_map.items():
        text = text.replace(key, value)
    return text


def _markdown_to_pdf_html(title: str, markdown_text: str, page_orientation: str) -> str:
    prepared_markdown = _replace_markdown_math(markdown_text)
    body_html = markdown_lib.markdown(
        prepared_markdown,
        extensions=["extra", "tables", "fenced_code", "sane_lists", "md_in_html"],
        output_format="html5",
    )
    title_html = f"<h1>{html.escape(title)}</h1>" if title else ""

    return f"""<!doctype html>
<html lang="pl">
<head>
<meta charset="utf-8">
<style>
  @page {{
    size: A4 {page_orientation};
    margin: 18mm 16mm 18mm 16mm;
  }}
  body {{
    font-family: "Adwaita Sans", "Inter", "Noto Sans", sans-serif;
    font-size: 10pt;
    line-height: 1.48;
    color: #2f3437;
    background: #ffffff;
    hyphens: auto;
  }}
  h1, h2, h3, h4, h5, h6 {{
    font-family: "Adwaita Sans", "Inter", "Noto Sans", sans-serif;
    font-weight: 700;
    line-height: 1.22;
    color: #2f3437;
    page-break-after: avoid;
    break-after: avoid-page;
  }}
  h1 {{ font-size: 16pt; margin: 0 0 12px 0; }}
  h2 {{ font-size: 14pt; margin: 18px 0 8px 0; }}
  h3 {{ font-size: 12pt; margin: 16px 0 7px 0; }}
  h4 {{ font-size: 11pt; margin: 14px 0 6px 0; }}
  h5, h6 {{ font-size: 10pt; margin: 12px 0 6px 0; }}
  p {{ margin: 0 0 9px 0; text-align: justify; }}
  ul, ol {{ margin: 0 0 10px 20px; padding-left: 0; }}
  li {{ margin: 0 0 4px 0; break-inside: avoid; }}
  blockquote {{ margin: 12px 0; padding: 8px 12px; background: #f7f8fa; border-radius: 6px; font-style: italic; }}
  table {{ width: 100%; border-collapse: collapse; table-layout: fixed; margin: 12px 0 14px 0; }}
  th, td {{ border: 1px solid #b9bec5; padding: 6px 8px; vertical-align: top; word-wrap: break-word; overflow-wrap: break-word; }}
  th {{ background: #eef1f4; text-align: left; }}
  code, pre {{ font-family: "Noto Sans Mono", "DejaVu Sans Mono", monospace; }}
  code {{ font-size: 9pt; background: #f3f4f6; padding: 1px 4px; border-radius: 4px; }}
  pre {{ font-size: 9pt; background: #f7f8fa; padding: 10px 12px; border-radius: 8px; white-space: pre-wrap; overflow-wrap: break-word; }}
  pre code {{ background: transparent; padding: 0; }}
  .math-inline, .math-inline math, .math-block, .math-block math {{ font-family: "STIX Two Math", "Latin Modern Math", serif; }}
  .math-inline {{ white-space: nowrap; }}
  .math-block {{ margin: 10px 0 12px 0; text-align: center; }}
  img {{ max-width: 100%; height: auto; }}
  hr {{ display: none; }}
</style>
</head>
<body>
{title_html}
{body_html}
</body>
</html>"""


def _detect_local_ip() -> str:
    with contextlib.suppress(Exception):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.connect(("8.8.8.8", 80))
        ip = sock.getsockname()[0]
        sock.close()
        if ipaddress.ip_address(ip).is_private:
            return ip
    return "127.0.0.1"


def _ensure_suffix(path: Path, suffix: str) -> None:
    if path.suffix.lower() != suffix:
        raise ValueError(f"Path must end with {suffix}")


def _read_csv_rows(path: Path, max_rows: int = MAX_CSV_ROWS) -> list[list[str]]:
    rows: list[list[str]] = []
    with open(path, "r", encoding="utf-8", newline="") as handle:
        reader = csv.reader(handle)
        for index, row in enumerate(reader):
            if index >= max_rows:
                break
            rows.append(row)
    return rows


def _write_csv_rows(path: Path, rows: list[list[str]]) -> None:
    with open(path, "w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerows(rows)


def _parse_csv_content(content: str) -> list[list[str]]:
    reader = csv.reader(io.StringIO(content))
    rows = [list(row) for row in reader]
    if len(rows) > MAX_CSV_ROWS:
        raise ValueError(f"CSV has too many rows. Maximum is {MAX_CSV_ROWS}.")
    if any(len(row) > MAX_CSV_COLUMNS for row in rows):
        raise ValueError(f"CSV has too many columns. Maximum is {MAX_CSV_COLUMNS}.")
    return rows


@mcp.tool(name="file_datetime", description=_tool_description("file_datetime"))
def file_datetime(timezone: str = DEFAULT_TIMEZONE) -> dict[str, Any]:
    """Returns the current date and time for the selected timezone."""
    now = datetime.now(ZoneInfo(timezone))
    return {
        "timezone": timezone,
        "iso": now.isoformat(),
        "date": now.strftime("%Y-%m-%d"),
        "time": now.strftime("%H:%M:%S"),
        "weekday": now.strftime("%A"),
    }


@mcp.tool(name="txt_read", description=_tool_description("txt_read"))
def txt_read(path: str, max_chars: int = 200000) -> dict[str, Any]:
    """Reads a text file from the workspace."""
    safe_path = _resolve_workspace_path(path)
    if not safe_path.exists():
        return {"error": "File not found"}
    if not safe_path.is_file():
        return {"error": "Path is not a file"}

    safe_max_chars = max(1, min(int(max_chars), MAX_TEXT_FILE_CHARS))
    return {"path": str(safe_path), "content": _read_text_file(safe_path, max_chars=safe_max_chars)}


@mcp.tool(name="txt_save", description=_tool_description("txt_save"))
def txt_save(path: str, content: str) -> dict[str, Any]:
    """Saves a text file inside the workspace."""
    safe_path = _resolve_workspace_path(path)
    _write_text_file(safe_path, content)
    return {"status": "ok", "path": str(safe_path)}


@mcp.tool(name="csv_read", description=_tool_description("csv_read"))
def csv_read(path: str, max_rows: int = 1000) -> dict[str, Any]:
    """Reads a CSV file from the workspace."""
    safe_path = _resolve_workspace_path(path)
    _ensure_suffix(safe_path, ".csv")
    if not safe_path.exists():
        return {"error": "File not found"}
    if not safe_path.is_file():
        return {"error": "Path is not a file"}

    safe_max_rows = max(1, min(int(max_rows), MAX_CSV_ROWS))
    rows = _read_csv_rows(safe_path, max_rows=safe_max_rows)
    return {
        "path": str(safe_path),
        "rows": rows,
        "rows_read": len(rows),
    }


@mcp.tool(name="csv_save", description=_tool_description("csv_save"))
def csv_save(path: str, content: str) -> dict[str, Any]:
    """Saves a CSV file inside the workspace."""
    safe_path = _resolve_workspace_path(path)
    _ensure_suffix(safe_path, ".csv")
    rows = _parse_csv_content(content)
    _write_csv_rows(safe_path, rows)
    return {"status": "ok", "path": str(safe_path), "rows_saved": len(rows)}


@mcp.tool(name="markdown_save", description=_tool_description("markdown_save"))
def markdown_save(path: str, content: str) -> dict[str, Any]:
    """Saves a Markdown file inside the workspace."""
    safe_path = _resolve_workspace_path(path)
    if safe_path.suffix.lower() != ".md":
        return {"error": "Path must end with .md"}
    _write_text_file(safe_path, content)
    return {"status": "ok", "path": str(safe_path)}


@mcp.tool(name="pdf_save", description=_tool_description("pdf_save"))
def pdf_save(
    path: str,
    title: str,
    content: str,
    page_orientation: str = "portrait",
) -> dict[str, Any]:
    """Generates a PDF file from Markdown content. The input content has no character limit, but the generated PDF may have at most 200 pages."""
    safe_path = _resolve_workspace_path(path)
    if safe_path.suffix.lower() != ".pdf":
        return {"error": "Path must end with .pdf"}
    normalized_orientation = _normalize_orientation(page_orientation)
    first_heading, body_markdown = _strip_first_h1(content)
    final_title = (first_heading or title).strip()
    html_document = _markdown_to_pdf_html(final_title, body_markdown, normalized_orientation)

    HTML(string=html_document, base_url=str(WORKSPACE_DIR)).write_pdf(str(safe_path))
    generated_page_count = len(PdfReader(str(safe_path)).pages)
    if generated_page_count > MAX_PDF_PAGES:
        with contextlib.suppress(FileNotFoundError):
            safe_path.unlink()
        return {"error": f"Generated PDF is too long. Maximum number of pages is {MAX_PDF_PAGES}."}

    return {
        "status": "ok",
        "path": str(safe_path),
        "title": final_title,
        "pages": generated_page_count,
        "page_size": "A4",
        "page_orientation": normalized_orientation,
    }


@mcp.tool(name="server_info_files", description=_tool_description("server_info_files"))
def server_info_files() -> dict[str, Any]:
    """Returns basic server endpoints and workspace information."""
    local_ip = _detect_local_ip()
    return {
        "project_name": PROJECT_NAME,
        "workspace_dir": str(WORKSPACE_DIR),
        "mcp_endpoint_local": f"http://127.0.0.1:{MCP_PORT}/mcp",
        "mcp_endpoint_lan": f"http://{local_ip}:{MCP_PORT}/mcp",
        "timezone": DEFAULT_TIMEZONE,
        "tool_language": TOOL_LANGUAGE if TOOL_LANGUAGE in SUPPORTED_TOOL_LANGUAGES else "en",
        "tools": [
            "file_datetime",
            "txt_read",
            "txt_save",
            "csv_read",
            "csv_save",
            "markdown_save",
            "pdf_save",
            "server_info_files",
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
  printf '  ├── mcp_workspace/\n'
  printf '  └── %s/\n' "${PROJECT_DIR_NAME}"
  printf '      ├── %s\n' "${ENV_FILE##*/}"
  printf '      ├── .venv/\n'
  printf '      └── app/\n'
  printf '          └── %s\n' "${SERVER_FILE_NAME}"

  printf '\nFull paths:\n'
  printf '  %-*s %s\n' "${path_label_width}" 'projects root directory:' "${ROOT_DIR}"
  printf '  %-*s %s\n' "${path_label_width}" 'project directory:' "${BASE_DIR}"
  printf '  %-*s %s\n' "${path_label_width}" 'application:' "${APP_DIR}"
  printf '  %-*s %s\n' "${path_label_width}" 'workspace:' "${WORKSPACE_DIR}"
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
