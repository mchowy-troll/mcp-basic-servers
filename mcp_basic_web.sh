#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_NAME="mcp_basic_web"
PROJECT_ROOT_DIR_NAME="mcp_server_tools"
PROJECT_DIR_NAME="mcp_basic_web"
SERVER_FILE_NAME="server.py"
SERVICE_NAME="mcp-basic-web.service"
SEARX_CONTAINER_NAME="mcp-basic-web-searxng"
DEFAULT_MCP_PORT="8001"
DEFAULT_SEARX_PORT="8081"
FALLBACK_TIMEZONE="UTC"
PYTHON_BIN="python3"
ENV_FILE_NAME=".env"

USER_NAME="${SUDO_USER:-$(whoami)}"
USER_HOME="$(getent passwd "${USER_NAME}" | cut -d: -f6)"
ROOT_DIR="${USER_HOME}/${PROJECT_ROOT_DIR_NAME}"
BASE_DIR="${ROOT_DIR}/${PROJECT_DIR_NAME}"
APP_DIR="${BASE_DIR}/app"
SEARX_DIR="${BASE_DIR}/searxng"
VENV_DIR="${BASE_DIR}/.venv"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
COMPOSE_FILE="${SEARX_DIR}/docker-compose.yml"
SEARX_SETTINGS_FILE="${SEARX_DIR}/settings.yml"
ENV_FILE="${BASE_DIR}/${ENV_FILE_NAME}"

LINUX_FAMILY=""
MCP_PORT="${DEFAULT_MCP_PORT}"
SEARX_PORT="${DEFAULT_SEARX_PORT}"
DEFAULT_TIMEZONE="${FALLBACK_TIMEZONE}"
TOOL_LANGUAGE="en"
UV_BIN=""
USE_SUDO_DOCKER="0"
COMPOSE_VARIANT=""

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
        curl ca-certificates python uv tzdata docker docker-compose
      ;;
    ubuntu)
      log "Installing system packages with apt"
      sudo apt-get update
      sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        curl ca-certificates python3 python3-venv python3-pip tzdata docker.io

      if sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin; then
        return 0
      fi

      if sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-v2; then
        return 0
      fi

      if sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose; then
        return 0
      fi

      fail "Could not install Docker Compose. Install Docker Compose and run this script again."
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

docker_cmd() {
  if [[ "${USE_SUDO_DOCKER}" == "1" ]]; then
    sudo docker "$@"
  else
    docker "$@"
  fi
}

compose_cmd() {
  case "${COMPOSE_VARIANT}" in
    plugin)
      docker_cmd compose "$@"
      ;;
    standalone)
      if [[ "${USE_SUDO_DOCKER}" == "1" ]]; then
        sudo docker-compose "$@"
      else
        docker-compose "$@"
      fi
      ;;
    *)
      fail "Docker Compose has not been detected."
      ;;
  esac
}

compose_display_command() {
  case "${COMPOSE_VARIANT}" in
    plugin)
      if [[ "${USE_SUDO_DOCKER}" == "1" ]]; then
        printf 'sudo docker compose'
      else
        printf 'docker compose'
      fi
      ;;
    standalone)
      if [[ "${USE_SUDO_DOCKER}" == "1" ]]; then
        printf 'sudo docker-compose'
      else
        printf 'docker-compose'
      fi
      ;;
    *)
      printf 'docker compose'
      ;;
  esac
}

enable_docker() {
  log "Enabling and starting Docker"
  sudo systemctl enable --now docker

  if docker info >/dev/null 2>&1; then
    USE_SUDO_DOCKER="0"
    return 0
  fi

  if sudo docker info >/dev/null 2>&1; then
    USE_SUDO_DOCKER="1"
    info "Docker is available through sudo in this session. The installer will use sudo docker when needed."
    return 0
  fi

  fail "Docker is installed but is not available. Check the Docker service and run this installer again."
}

detect_compose() {
  log "Checking Docker Compose"

  if docker_cmd compose version >/dev/null 2>&1; then
    COMPOSE_VARIANT="plugin"
    return 0
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    if [[ "${USE_SUDO_DOCKER}" == "1" ]]; then
      if sudo docker-compose version >/dev/null 2>&1; then
        COMPOSE_VARIANT="standalone"
        return 0
      fi
    else
      if docker-compose version >/dev/null 2>&1; then
        COMPOSE_VARIANT="standalone"
        return 0
      fi
    fi
  fi

  fail "Docker Compose was not detected after installation."
}

random_secret() {
  "${PYTHON_BIN}" - <<'PY'
import secrets
print(secrets.token_urlsafe(48))
PY
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

searx_container_exists() {
  docker_cmd ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "${SEARX_CONTAINER_NAME}"
}

remove_existing_searx_container() {
  if searx_container_exists; then
    warn "Removing earlier ${SEARX_CONTAINER_NAME} container before recreating SearXNG."
    docker_cmd rm -f "${SEARX_CONTAINER_NAME}" >/dev/null
    sleep 1
  fi
}

maybe_remove_existing_searx_container_for_port() {
  if ! searx_container_exists; then
    return 1
  fi

  warn "The SearXNG port is busy and an earlier ${SEARX_CONTAINER_NAME} container exists."
  remove_existing_searx_container
  return 0
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

prompt_searx_port() {
  log "SearXNG port selection"
  printf 'Default local SearXNG port for %s is %s.\n' "${PROJECT_NAME}" "${DEFAULT_SEARX_PORT}"

  local selected
  while true; do
    printf 'SearXNG port [default: %s]: ' "${DEFAULT_SEARX_PORT}"
    read -r selected
    selected="${selected:-${DEFAULT_SEARX_PORT}}"

    if [[ ! "${selected}" =~ ^[0-9]+$ ]]; then
      warn "Port must be a number."
      continue
    fi

    if (( selected < 1024 || selected > 65535 )); then
      warn "Choose a port in the range 1024-65535."
      continue
    fi

    if [[ "${selected}" == "${MCP_PORT}" ]]; then
      warn "SearXNG port must be different from the MCP port."
      continue
    fi

    if port_is_free "${selected}"; then
      SEARX_PORT="${selected}"
      return 0
    fi

    if maybe_remove_existing_searx_container_for_port && port_is_free "${selected}"; then
      SEARX_PORT="${selected}"
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
  log "Creating application and SearXNG directories"
  mkdir -p \
    "${APP_DIR}" \
    "${SEARX_DIR}"
}

write_env_file() {
  local searx_secret="$1"
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
SEARX_DIR=${SEARX_DIR}
VENV_DIR=${VENV_DIR}
MCP_PORT=${MCP_PORT}
SEARX_PORT=${SEARX_PORT}
DEFAULT_TIMEZONE=${DEFAULT_TIMEZONE}
TOOL_LANGUAGE=${TOOL_LANGUAGE}
SEARX_SECRET=${searx_secret}
SEARX_SEARCH_URL=http://127.0.0.1:${SEARX_PORT}/search
EOF
  chmod 600 "${ENV_FILE}"
}

write_searx_configuration() {
  local searx_secret="$1"
  local searx_base_url="http://127.0.0.1:${SEARX_PORT}/"

  log "Writing SearXNG configuration"
  cat > "${COMPOSE_FILE}" <<EOF
services:
  searxng:
    image: searxng/searxng:latest
    container_name: ${SEARX_CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "127.0.0.1:${SEARX_PORT}:8080"
    volumes:
      - ./settings.yml:/etc/searxng/settings.yml:ro
    environment:
      - SEARXNG_BASE_URL=${searx_base_url}
EOF

  cat > "${SEARX_SETTINGS_FILE}" <<EOF
use_default_settings: true

general:
  instance_name: "${PROJECT_NAME} Local SearXNG"

search:
  safe_search: 0
  autocomplete: ""
  default_lang: "auto"
  formats:
    - html
    - json

server:
  secret_key: "${searx_secret}"
  limiter: false
  image_proxy: false
  bind_address: "0.0.0.0"
  port: 8080

ui:
  static_use_hash: true
EOF
}

start_searx() {
  log "Starting SearXNG with Docker Compose"
  remove_existing_searx_container
  (
    cd "${SEARX_DIR}"
    compose_cmd up -d
  )
}

wait_for_searx() {
  local attempt response
  for attempt in $(seq 1 60); do
    response="$(curl -fsS "http://127.0.0.1:${SEARX_PORT}/search?q=test&format=json" 2>/dev/null || true)"
    if [[ -n "${response}" ]] && SEARX_RESPONSE="${response}" "${PYTHON_BIN}" - <<'PY' >/dev/null 2>&1
import json
import os
payload = json.loads(os.environ["SEARX_RESPONSE"])
raise SystemExit(0 if isinstance(payload, dict) and isinstance(payload.get("results"), list) else 1)
PY
    then
      return 0
    fi
    sleep 1
  done
  return 1
}

test_searx() {
  log "Checking whether SearXNG is ready"

  if wait_for_searx; then
    info "SearXNG responds locally on port ${SEARX_PORT}."
    return 0
  fi

  warn "SearXNG did not become ready. Recent container logs follow."
  (
    cd "${SEARX_DIR}"
    compose_cmd logs --tail 80 || true
  )
  fail "SearXNG did not become ready on port ${SEARX_PORT}."
}

create_virtualenv() {
  log "Creating Python environment"
  "${UV_BIN}" venv "${VENV_DIR}"

  log "Installing Python dependencies"
  "${UV_BIN}" pip install --python "${VENV_DIR}/bin/python" \
    mcp starlette uvicorn httpx trafilatura
}

write_python_server() {
  log "Writing MCP server Python file"
  cat > "${APP_DIR}/${SERVER_FILE_NAME}" <<'PY'
from __future__ import annotations

import contextlib
import ipaddress
import os
import socket
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlparse
from zoneinfo import ZoneInfo

import httpx
import trafilatura
from mcp.server.fastmcp import FastMCP
from starlette.applications import Starlette
from starlette.middleware.cors import CORSMiddleware
from starlette.routing import Mount

PROJECT_NAME = os.environ.get("PROJECT_NAME", "mcp_basic_web")
DEFAULT_TIMEZONE = os.environ.get("DEFAULT_TIMEZONE", "UTC")
TOOL_LANGUAGE = os.environ.get("TOOL_LANGUAGE", "en").strip().lower()
MCP_PORT = int(os.environ.get("MCP_PORT", "8001"))
SEARX_PORT = int(os.environ.get("SEARX_PORT", "8081"))
SEARX_SEARCH_URL = os.environ.get("SEARX_SEARCH_URL", f"http://127.0.0.1:{SEARX_PORT}/search")
BASE_DIR = Path(
    os.environ.get("BASE_DIR", str(Path.home() / "mcp_server_tools" / "mcp_basic_web"))
).resolve()

MAX_WEBPAGE_CHARS = 50_000
MAX_SEARCH_RESULTS = 20

SUPPORTED_TOOL_LANGUAGES = {"pl", "en", "de", "fr", "it", "es"}

TOOL_DESCRIPTIONS = {
    "pl": {
        "datetime_get": "Zwraca aktualną datę i godzinę dla wybranej strefy czasowej.\nUżywaj tego narzędzia, gdy pytanie zależy od dzisiejszej daty, aktualnego czasu, strefy czasowej lub kolejności najnowszych wydarzeń.",
        "web_search": "Wyszukuje bieżące informacje w internecie przez lokalną instancję SearXNG.\nUżywaj tego narzędzia do aktualnych lub zależnych od czasu informacji, w tym dzisiejszych wiadomości, najnowszych wydarzeń, aktualnych cen, kursów walut, pogody, aktualizacji oprogramowania i wszystkiego, co może być nowsze niż wiedza modelu.\nMaksymalna liczba wyników: 1-20.",
        "webpage_fetch": "Pobiera stronę internetową i zwraca wyodrębniony czytelny tekst.\nMaksymalna długość treści: 100-50000 znaków.",
        "server_info_web": "Zwraca podstawowe informacje o serwerze web i lokalne adresy MCP.",
    },
    "en": {
        "datetime_get": "Returns current date and time for the selected timezone.\nUse this tool when a question depends on today's date, the current time, timezone, or the order of recent events.",
        "web_search": "Searches the live web through the local SearXNG instance.\nUse this tool for current or time-sensitive information, including today's news, recent events, current prices, exchange rates, weather, software updates, and anything that may be newer than the model's built-in knowledge.\nResults maximum count: 1-20.",
        "webpage_fetch": "Fetches a webpage and returns extracted readable text.\nContent maximum length: 100-50000 characters.",
        "server_info_web": "Returns basic web server information and local MCP endpoints.",
    },
    "de": {
        "datetime_get": "Gibt das aktuelle Datum und die aktuelle Uhrzeit für die gewählte Zeitzone zurück.\nVerwende dieses Tool, wenn eine Frage vom heutigen Datum, der aktuellen Uhrzeit, der Zeitzone oder der Reihenfolge aktueller Ereignisse abhängt.",
        "web_search": "Durchsucht das aktuelle Web über die lokale SearXNG-Instanz.\nVerwende dieses Tool für aktuelle oder zeitkritische Informationen, einschließlich heutiger Nachrichten, aktueller Ereignisse, aktueller Preise, Wechselkurse, Wetter, Software-Updates und allem, was neuer sein kann als das eingebaute Wissen des Modells.\nMaximale Ergebnisanzahl: 1-20.",
        "webpage_fetch": "Ruft eine Webseite ab und gibt extrahierten lesbaren Text zurück.\nMaximale Inhaltslänge: 100-50000 Zeichen.",
        "server_info_web": "Gibt grundlegende Informationen zum Webserver und lokale MCP-Adressen zurück.",
    },
    "fr": {
        "datetime_get": "Retourne la date et l'heure actuelles pour le fuseau horaire choisi.\nUtilise cet outil lorsqu'une question dépend de la date du jour, de l'heure actuelle, du fuseau horaire ou de l'ordre des événements récents.",
        "web_search": "Recherche sur le web en direct via l'instance locale SearXNG.\nUtilise cet outil pour les informations actuelles ou sensibles au temps, notamment les nouvelles du jour, les événements récents, les prix actuels, les taux de change, la météo, les mises à jour logicielles et tout ce qui peut être plus récent que les connaissances intégrées du modèle.\nNombre maximal de résultats : 1-20.",
        "webpage_fetch": "Récupère une page web et retourne le texte lisible extrait.\nLongueur maximale du contenu : 100-50000 caractères.",
        "server_info_web": "Retourne les informations de base du serveur web et les adresses MCP locales.",
    },
    "it": {
        "datetime_get": "Restituisce la data e l'ora attuali per il fuso orario scelto.\nUsa questo strumento quando una domanda dipende dalla data odierna, dall'ora attuale, dal fuso orario o dall'ordine degli eventi recenti.",
        "web_search": "Cerca nel web in tempo reale tramite l'istanza locale SearXNG.\nUsa questo strumento per informazioni attuali o sensibili al tempo, incluse le notizie di oggi, eventi recenti, prezzi attuali, tassi di cambio, meteo, aggiornamenti software e tutto ciò che potrebbe essere più recente della conoscenza integrata del modello.\nNumero massimo di risultati: 1-20.",
        "webpage_fetch": "Scarica una pagina web e restituisce il testo leggibile estratto.\nLunghezza massima del contenuto: 100-50000 caratteri.",
        "server_info_web": "Restituisce le informazioni di base del server web e gli indirizzi MCP locali.",
    },
    "es": {
        "datetime_get": "Devuelve la fecha y hora actuales para la zona horaria elegida.\nUsa esta herramienta cuando una pregunta dependa de la fecha de hoy, la hora actual, la zona horaria o el orden de eventos recientes.",
        "web_search": "Busca en la web en vivo mediante la instancia local de SearXNG.\nUsa esta herramienta para información actual o sensible al tiempo, incluidas noticias de hoy, eventos recientes, precios actuales, tipos de cambio, clima, actualizaciones de software y cualquier cosa que pueda ser más reciente que el conocimiento integrado del modelo.\nCantidad máxima de resultados: 1-20.",
        "webpage_fetch": "Obtiene una página web y devuelve el texto legible extraído.\nLongitud máxima del contenido: 100-50000 caracteres.",
        "server_info_web": "Devuelve información básica del servidor web y direcciones MCP locales.",
    },
}

WEB_SEARCH_USAGE_HINTS = {
    "pl": "To są wyniki bieżącego wyszukiwania przez lokalną instancję SearXNG. Użyj ich jako aktualnego kontekstu, szczególnie przy pytaniach o dzisiejsze wiadomości, najnowsze wydarzenia, ceny, kursy, pogodę lub inne informacje zależne od czasu.",
    "en": "These are live web search results from the local SearXNG instance. Use them as current context, especially for questions about today's news, recent events, prices, exchange rates, weather, or other time-sensitive information.",
    "de": "Dies sind aktuelle Websuchergebnisse der lokalen SearXNG-Instanz. Nutze sie als aktuellen Kontext, besonders bei Fragen zu heutigen Nachrichten, aktuellen Ereignissen, Preisen, Wechselkursen, Wetter oder anderen zeitkritischen Informationen.",
    "fr": "Ce sont des résultats de recherche web en direct depuis l'instance locale SearXNG. Utilise-les comme contexte actuel, surtout pour les questions sur les nouvelles du jour, les événements récents, les prix, les taux de change, la météo ou d'autres informations sensibles au temps.",
    "it": "Questi sono risultati di ricerca web in tempo reale dall'istanza locale SearXNG. Usali come contesto attuale, soprattutto per domande su notizie di oggi, eventi recenti, prezzi, tassi di cambio, meteo o altre informazioni sensibili al tempo.",
    "es": "Estos son resultados de búsqueda web en vivo desde la instancia local de SearXNG. Úsalos como contexto actual, especialmente para preguntas sobre noticias de hoy, eventos recientes, precios, tipos de cambio, clima u otra información sensible al tiempo.",
}

DATETIME_USAGE_HINTS = {
    "pl": "Użyj tej wartości jako aktualnego kontekstu daty i czasu przy pytaniach zależnych od czasu.",
    "en": "Use this value as the current date and time context for time-sensitive questions.",
    "de": "Nutze diesen Wert als aktuellen Datums- und Zeitkontext für zeitkritische Fragen.",
    "fr": "Utilise cette valeur comme contexte actuel de date et d'heure pour les questions sensibles au temps.",
    "it": "Usa questo valore come contesto attuale di data e ora per domande sensibili al tempo.",
    "es": "Usa este valor como contexto actual de fecha y hora para preguntas sensibles al tiempo.",
}

SERVER_USAGE_NOTES = {
    "pl": [
        "web_search jest przeznaczone do bieżących i zależnych od czasu informacji, których może nie być w wiedzy modelu.",
        "datetime_get pomaga ustalić aktualną datę, czas i strefę czasową przed odpowiedziami dotyczącymi dziś, teraz, najnowszych wydarzeń lub kolejności zdarzeń.",
        "webpage_fetch służy do pobierania i czytania konkretnej strony znalezionej wcześniej lub podanej przez użytkownika.",
    ],
    "en": [
        "web_search is intended for current and time-sensitive information that may not be in the model's built-in knowledge.",
        "datetime_get helps establish the current date, time, and timezone before answering questions about today, now, latest events, or event order.",
        "webpage_fetch is intended for fetching and reading a specific page found earlier or provided by the user.",
    ],
    "de": [
        "web_search ist für aktuelle und zeitkritische Informationen gedacht, die möglicherweise nicht im eingebauten Wissen des Modells enthalten sind.",
        "datetime_get hilft, aktuelles Datum, Uhrzeit und Zeitzone festzustellen, bevor Fragen zu heute, jetzt, neuesten Ereignissen oder der Reihenfolge von Ereignissen beantwortet werden.",
        "webpage_fetch dient zum Abrufen und Lesen einer bestimmten Seite, die zuvor gefunden oder vom Nutzer angegeben wurde.",
    ],
    "fr": [
        "web_search est destiné aux informations actuelles et sensibles au temps qui peuvent ne pas figurer dans les connaissances intégrées du modèle.",
        "datetime_get aide à établir la date, l'heure et le fuseau horaire actuels avant de répondre aux questions sur aujourd'hui, maintenant, les derniers événements ou l'ordre des événements.",
        "webpage_fetch sert à récupérer et lire une page précise trouvée auparavant ou fournie par l'utilisateur.",
    ],
    "it": [
        "web_search è pensato per informazioni attuali e sensibili al tempo che potrebbero non essere presenti nella conoscenza integrata del modello.",
        "datetime_get aiuta a stabilire data, ora e fuso orario attuali prima di rispondere a domande su oggi, ora, ultimi eventi o ordine degli eventi.",
        "webpage_fetch serve a recuperare e leggere una pagina specifica trovata in precedenza o fornita dall'utente.",
    ],
    "es": [
        "web_search está pensado para información actual y sensible al tiempo que puede no estar en el conocimiento integrado del modelo.",
        "datetime_get ayuda a establecer la fecha, hora y zona horaria actuales antes de responder preguntas sobre hoy, ahora, eventos recientes o el orden de los eventos.",
        "webpage_fetch sirve para obtener y leer una página específica encontrada antes o proporcionada por el usuario.",
    ],
}


mcp = FastMCP(
    PROJECT_NAME,
    stateless_http=True,
    json_response=True,
    host="0.0.0.0",
)


def _tool_language() -> str:
    return TOOL_LANGUAGE if TOOL_LANGUAGE in SUPPORTED_TOOL_LANGUAGES else "en"


def _tool_description(tool_name: str) -> str:
    return TOOL_DESCRIPTIONS[_tool_language()][tool_name]


def _datetime_usage_hint() -> str:
    return DATETIME_USAGE_HINTS[_tool_language()]


def _web_search_usage_hint() -> str:
    return WEB_SEARCH_USAGE_HINTS[_tool_language()]


def _server_usage_notes() -> list[str]:
    return SERVER_USAGE_NOTES[_tool_language()]


def _timezone(name: str) -> ZoneInfo | timezone:
    try:
        return ZoneInfo((name or DEFAULT_TIMEZONE).strip() or DEFAULT_TIMEZONE)
    except Exception:
        return timezone.utc


def _now() -> datetime:
    return datetime.now(_timezone(DEFAULT_TIMEZONE))


def _detect_local_ip() -> str:
    with contextlib.suppress(Exception):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.connect(("8.8.8.8", 80))
        ip = sock.getsockname()[0]
        sock.close()
        if ipaddress.ip_address(ip).is_private:
            return ip
    return "127.0.0.1"


def _validate_url(url: str) -> str:
    cleaned = (url or "").strip()
    if not cleaned:
        raise ValueError("URL must not be empty.")

    parsed = urlparse(cleaned)
    if parsed.scheme not in {"http", "https"}:
        raise ValueError("Only http and https URLs are supported.")
    if not parsed.netloc:
        raise ValueError("URL must include a host name.")
    return cleaned


@mcp.tool(name="datetime_get", description=_tool_description("datetime_get"))
def datetime_get(timezone: str = DEFAULT_TIMEZONE) -> dict[str, Any]:
    tz = _timezone(timezone)
    now = datetime.now(tz)
    return {
        "timezone": getattr(tz, "key", str(tz)),
        "iso": now.isoformat(),
        "date": now.strftime("%Y-%m-%d"),
        "time": now.strftime("%H:%M:%S"),
        "weekday": now.strftime("%A"),
        "usage_hint": _datetime_usage_hint(),
    }


@mcp.tool(name="web_search", description=_tool_description("web_search"))
def web_search(query: str, max_results: int = 5) -> dict[str, Any]:
    clean_query = (query or "").strip()
    if not clean_query:
        raise ValueError("Query must not be empty.")

    safe_max_results = max(1, min(int(max_results), MAX_SEARCH_RESULTS))
    now = _now()
    with httpx.Client(timeout=25.0) as client:
        response = client.get(
            SEARX_SEARCH_URL,
            params={"q": clean_query, "format": "json", "language": "auto"},
        )
        response.raise_for_status()
        payload = response.json()

    results = []
    for item in payload.get("results", [])[:safe_max_results]:
        results.append(
            {
                "title": item.get("title", ""),
                "url": item.get("url", ""),
                "snippet": item.get("content", ""),
                "engine": item.get("engine", ""),
            }
        )

    return {
        "query": clean_query,
        "count": len(results),
        "current_datetime": now.isoformat(),
        "current_date": now.strftime("%Y-%m-%d"),
        "current_timezone": DEFAULT_TIMEZONE,
        "usage_hint": _web_search_usage_hint(),
        "results": results,
    }


@mcp.tool(name="webpage_fetch", description=_tool_description("webpage_fetch"))
def webpage_fetch(url: str, max_chars: int = 50000) -> dict[str, Any]:
    clean_url = _validate_url(url)
    safe_max_chars = max(100, min(int(max_chars), MAX_WEBPAGE_CHARS))
    now = _now()
    headers = {"User-Agent": "Mozilla/5.0 (compatible; mcp_basic_web/1.0)"}
    with httpx.Client(follow_redirects=True, timeout=25.0, headers=headers) as client:
        response = client.get(clean_url)
        response.raise_for_status()
        html_text = response.text

    extracted = trafilatura.extract(html_text, include_links=True, include_images=False)
    text = extracted if extracted else html_text
    return {
        "url": clean_url,
        "status_code": response.status_code,
        "current_datetime": now.isoformat(),
        "current_date": now.strftime("%Y-%m-%d"),
        "current_timezone": DEFAULT_TIMEZONE,
        "content_preview": text[:safe_max_chars],
    }


@mcp.tool(name="server_info_web", description=_tool_description("server_info_web"))
def server_info_web() -> dict[str, Any]:
    local_ip = _detect_local_ip()
    return {
        "project_name": PROJECT_NAME,
        "project_dir": str(BASE_DIR),
        "tool_language": _tool_language(),
        "timezone": DEFAULT_TIMEZONE,
        "mcp_endpoint_local": f"http://127.0.0.1:{MCP_PORT}/mcp",
        "mcp_endpoint_lan": f"http://{local_ip}:{MCP_PORT}/mcp",
        "searxng_endpoint": f"http://127.0.0.1:{SEARX_PORT}",
        "usage_notes": _server_usage_notes(),
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
After=network-online.target docker.service
Wants=network-online.target docker.service

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
  log "Checking whether the MCP service is running"

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
  local compose_display
  lan_ip="$(detect_lan_ip)"
  compose_display="$(compose_display_command)"

  printf '\nInstallation completed successfully.\n\n'

  printf '%-*s %s\n' "${summary_label_width}" 'MCP server name:' "${PROJECT_NAME}"
  printf '%-*s %s\n' "${summary_label_width}" 'MCP address on this computer:' "http://127.0.0.1:${MCP_PORT}/mcp"
  printf '%-*s %s\n' "${summary_label_width}" 'MCP address for other computers in the local network:' "http://${lan_ip}:${MCP_PORT}/mcp"
  printf '%-*s %s\n' "${summary_label_width}" 'Selected MCP tool description language:' "${TOOL_LANGUAGE}"
  printf '%-*s %s\n' "${summary_label_width}" 'Server timezone:' "${DEFAULT_TIMEZONE}"
  printf '%-*s %s\n' "${summary_label_width}" 'Local SearXNG endpoint:' "http://127.0.0.1:${SEARX_PORT}"

  printf '\nProject directory structure:\n'
  printf '  %s\n' "${ROOT_DIR}"
  printf '  └── %s/\n' "${PROJECT_DIR_NAME}"
  printf '      ├── %s\n' "${ENV_FILE##*/}"
  printf '      ├── .venv/\n'
  printf '      ├── app/\n'
  printf '      │   └── %s\n' "${SERVER_FILE_NAME}"
  printf '      └── searxng/\n'
  printf '          ├── docker-compose.yml\n'
  printf '          └── settings.yml\n'

  printf '\nFull paths:\n'
  printf '  %-*s %s\n' "${path_label_width}" 'projects root directory:' "${ROOT_DIR}"
  printf '  %-*s %s\n' "${path_label_width}" 'project directory:' "${BASE_DIR}"
  printf '  %-*s %s\n' "${path_label_width}" 'application:' "${APP_DIR}"
  printf '  %-*s %s\n' "${path_label_width}" 'searxng:' "${SEARX_DIR}"
  printf '  %-*s %s\n' "${path_label_width}" 'virtualenv:' "${VENV_DIR}"

  printf '\n'
  printf '  %-*s %s\n' "${path_label_width}" 'Service logs:' "journalctl -u ${SERVICE_NAME} -f"
  printf '  %-*s %s\n' "${path_label_width}" 'Service status:' "systemctl status ${SERVICE_NAME}"
  printf '  %-*s %s\n' "${path_label_width}" 'SearXNG logs:' "cd ${SEARX_DIR} && ${compose_display} logs -f"
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
  require_command docker
  ensure_uv
  enable_docker
  detect_compose

  prompt_mcp_port
  prompt_searx_port
  prompt_tool_language
  set_timezone_from_system

  create_directories
  local searx_secret
  searx_secret="$(random_secret)"
  write_env_file "${searx_secret}"
  write_searx_configuration "${searx_secret}"
  start_searx
  test_searx
  create_virtualenv
  write_python_server
  validate_generated_server
  write_systemd_service
  start_service
  test_service
  print_summary
}

main "$@"
