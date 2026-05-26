#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_NAME="mcp_basic_weather"
PROJECT_ROOT_DIR_NAME="mcp_server_tools"
PROJECT_DIR_NAME="mcp_basic_weather"
SERVER_FILE_NAME="server.py"
SERVICE_NAME="mcp-basic-weather.service"
DEFAULT_MCP_PORT="8006"
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
import socket
from pathlib import Path
from typing import Any

import httpx
from mcp.server.fastmcp import FastMCP
from starlette.applications import Starlette
from starlette.middleware.cors import CORSMiddleware
from starlette.routing import Mount

PROJECT_NAME = os.environ.get("PROJECT_NAME", "mcp_basic_weather")
DEFAULT_TIMEZONE = os.environ.get("DEFAULT_TIMEZONE", "UTC")
TOOL_LANGUAGE = os.environ.get("TOOL_LANGUAGE", "en").strip().lower()
MCP_PORT = int(os.environ.get("MCP_PORT", "8006"))
BASE_DIR = Path(
    os.environ.get("BASE_DIR", str(Path.home() / "mcp_server_tools" / "mcp_basic_weather"))
).resolve()

OPEN_METEO_FORECAST_URL = "https://api.open-meteo.com/v1/forecast"
OPEN_METEO_GEOCODING_URL = "https://geocoding-api.open-meteo.com/v1/search"

SUPPORTED_TOOL_LANGUAGES = {"pl", "en", "de", "fr", "it", "es"}

TOOL_DESCRIPTIONS = {
    "pl": {
        "weather_current": "Zwraca aktualną pogodę dla wybranych współrzędnych.",
        "weather_hourly": "Zwraca godzinową prognozę pogody dla wybranych współrzędnych.\nZakres godzin: 1-168.",
        "weather_daily": "Zwraca dzienną prognozę pogody dla wybranych współrzędnych.\nZakres dni: 1-16.",
        "geocode_city": "Wyszukuje miasto lub miejsce przez Open-Meteo Geocoding.\nMaksymalna liczba wyników: 1-10 lokalizacji.",
        "weather_by_city": "Wyszukuje miasto i zwraca aktualną pogodę dla najlepszego dopasowania.",
        "server_info_weather": "Zwraca podstawowe informacje o serwerze pogody i lokalne adresy MCP.",
    },
    "en": {
        "weather_current": "Returns current weather for the selected coordinates.",
        "weather_hourly": "Returns an hourly weather forecast for the selected coordinates.\nHours range: 1-168.",
        "weather_daily": "Returns a daily weather forecast for the selected coordinates.\nDays range: 1-16.",
        "geocode_city": "Searches for a city or place with Open-Meteo Geocoding.\nResults maximum count: 1-10 locations.",
        "weather_by_city": "Finds a city and returns current weather for the best match.",
        "server_info_weather": "Returns basic weather server information and local MCP endpoints.",
    },
    "de": {
        "weather_current": "Gibt das aktuelle Wetter für die gewählten Koordinaten zurück.",
        "weather_hourly": "Gibt eine stündliche Wettervorhersage für die gewählten Koordinaten zurück.\nStundenbereich: 1-168.",
        "weather_daily": "Gibt eine tägliche Wettervorhersage für die gewählten Koordinaten zurück.\nTagebereich: 1-16.",
        "geocode_city": "Sucht eine Stadt oder einen Ort mit Open-Meteo Geocoding.\nMaximale Ergebnisanzahl: 1-10 Orte.",
        "weather_by_city": "Findet eine Stadt und gibt das aktuelle Wetter für den besten Treffer zurück.",
        "server_info_weather": "Gibt grundlegende Informationen zum Wetterserver und lokale MCP-Adressen zurück.",
    },
    "fr": {
        "weather_current": "Retourne la météo actuelle pour les coordonnées choisies.",
        "weather_hourly": "Retourne une prévision météo horaire pour les coordonnées choisies.\nPlage horaire : 1-168.",
        "weather_daily": "Retourne une prévision météo quotidienne pour les coordonnées choisies.\nPlage de jours : 1-16.",
        "geocode_city": "Recherche une ville ou un lieu avec Open-Meteo Geocoding.\nNombre maximal de résultats : 1-10 lieux.",
        "weather_by_city": "Trouve une ville et retourne la météo actuelle pour le meilleur résultat.",
        "server_info_weather": "Retourne les informations de base du serveur météo et les adresses MCP locales.",
    },
    "it": {
        "weather_current": "Restituisce il meteo attuale per le coordinate scelte.",
        "weather_hourly": "Restituisce una previsione meteo oraria per le coordinate scelte.\nIntervallo ore: 1-168.",
        "weather_daily": "Restituisce una previsione meteo giornaliera per le coordinate scelte.\nIntervallo giorni: 1-16.",
        "geocode_city": "Cerca una città o un luogo con Open-Meteo Geocoding.\nNumero massimo di risultati: 1-10 località.",
        "weather_by_city": "Trova una città e restituisce il meteo attuale per il miglior risultato.",
        "server_info_weather": "Restituisce le informazioni di base del server meteo e gli indirizzi MCP locali.",
    },
    "es": {
        "weather_current": "Devuelve el clima actual para las coordenadas elegidas.",
        "weather_hourly": "Devuelve una previsión meteorológica por horas para las coordenadas elegidas.\nRango de horas: 1-168.",
        "weather_daily": "Devuelve una previsión meteorológica diaria para las coordenadas elegidas.\nRango de días: 1-16.",
        "geocode_city": "Busca una ciudad o lugar con Open-Meteo Geocoding.\nCantidad máxima de resultados: 1-10 ubicaciones.",
        "weather_by_city": "Busca una ciudad y devuelve el clima actual para la mejor coincidencia.",
        "server_info_weather": "Devuelve información básica del servidor del clima y direcciones MCP locales.",
    },
}

DEFAULT_HOURLY_VARS = [
    "temperature_2m",
    "relative_humidity_2m",
    "apparent_temperature",
    "precipitation_probability",
    "precipitation",
    "pressure_msl",
    "cloud_cover",
    "visibility",
    "wind_speed_10m",
    "wind_gusts_10m",
    "wind_direction_10m",
    "weather_code",
]

DEFAULT_DAILY_VARS = [
    "weather_code",
    "temperature_2m_max",
    "temperature_2m_min",
    "precipitation_sum",
    "precipitation_probability_max",
    "wind_speed_10m_max",
    "wind_gusts_10m_max",
    "sunrise",
    "sunset",
]

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


def _weather_code_description(code: int) -> str:
    mapping = {
        0: "bezchmurnie",
        1: "głównie bezchmurnie",
        2: "częściowe zachmurzenie",
        3: "duże zachmurzenie",
        45: "mgła",
        48: "osadzająca się mgła",
        51: "lekka mżawka",
        53: "umiarkowana mżawka",
        55: "gęsta mżawka",
        56: "lekka marznąca mżawka",
        57: "gęsta marznąca mżawka",
        61: "lekki deszcz",
        63: "umiarkowany deszcz",
        65: "silny deszcz",
        66: "lekki marznący deszcz",
        67: "silny marznący deszcz",
        71: "lekki śnieg",
        73: "umiarkowany śnieg",
        75: "silny śnieg",
        77: "ziarna śnieżne",
        80: "lekkie przelotne opady deszczu",
        81: "umiarkowane przelotne opady deszczu",
        82: "gwałtowne przelotne opady deszczu",
        85: "lekkie przelotne opady śniegu",
        86: "silne przelotne opady śniegu",
        95: "burza",
        96: "burza z lekkim gradem",
        99: "burza z silnym gradem",
    }
    return mapping.get(code, "nieznane warunki pogodowe")


def _build_client() -> httpx.Client:
    return httpx.Client(timeout=30.0, headers={"User-Agent": "mcp_basic_weather/1.0"})


def _base_units_params() -> dict[str, Any]:
    return {
        "temperature_unit": "celsius",
        "wind_speed_unit": "kmh",
        "precipitation_unit": "mm",
        "timezone": DEFAULT_TIMEZONE,
    }


def _fetch_forecast(params: dict[str, Any]) -> dict[str, Any]:
    full_params = {**_base_units_params(), **params}
    with _build_client() as client:
        response = client.get(OPEN_METEO_FORECAST_URL, params=full_params)
        response.raise_for_status()
        return response.json()


def _fetch_geocoding(name: str, count: int = 5, language: str = "pl", country_code: str = "") -> dict[str, Any]:
    params: dict[str, Any] = {
        "name": name,
        "count": max(1, min(int(count), 10)),
        "language": language,
        "format": "json",
    }
    if country_code:
        params["countryCode"] = country_code

    with _build_client() as client:
        response = client.get(OPEN_METEO_GEOCODING_URL, params=params)
        response.raise_for_status()
        return response.json()


def _location_payload(source: dict[str, Any]) -> dict[str, Any]:
    return {
        "latitude": source.get("latitude"),
        "longitude": source.get("longitude"),
        "timezone": source.get("timezone", DEFAULT_TIMEZONE),
        "elevation_m": source.get("elevation"),
    }


@mcp.tool(name="weather_current", description=_tool_description("weather_current"))
def weather_current(latitude: float, longitude: float) -> dict[str, Any]:
    payload = _fetch_forecast(
        {
            "latitude": latitude,
            "longitude": longitude,
            "current": [
                "temperature_2m",
                "relative_humidity_2m",
                "apparent_temperature",
                "is_day",
                "precipitation",
                "pressure_msl",
                "cloud_cover",
                "wind_speed_10m",
                "wind_gusts_10m",
                "wind_direction_10m",
                "weather_code",
            ],
        }
    )

    current = payload.get("current", {})
    units = payload.get("current_units", {})
    weather_code = int(current.get("weather_code", -1))

    return {
        **_location_payload(payload),
        "observation_time": current.get("time"),
        "temperature_c": current.get("temperature_2m"),
        "apparent_temperature_c": current.get("apparent_temperature"),
        "relative_humidity_percent": current.get("relative_humidity_2m"),
        "precipitation_mm": current.get("precipitation"),
        "pressure_hpa": current.get("pressure_msl"),
        "cloud_cover_percent": current.get("cloud_cover"),
        "wind_speed_kmh": current.get("wind_speed_10m"),
        "wind_gusts_kmh": current.get("wind_gusts_10m"),
        "wind_direction_deg": current.get("wind_direction_10m"),
        "weather_code": weather_code,
        "weather_description": _weather_code_description(weather_code),
        "is_day": bool(current.get("is_day", 0)),
        "units": {
            "temperature": units.get("temperature_2m", "°C"),
            "apparent_temperature": units.get("apparent_temperature", "°C"),
            "relative_humidity": units.get("relative_humidity_2m", "%"),
            "precipitation": units.get("precipitation", "mm"),
            "pressure": units.get("pressure_msl", "hPa"),
            "cloud_cover": units.get("cloud_cover", "%"),
            "wind_speed": units.get("wind_speed_10m", "km/h"),
            "wind_gusts": units.get("wind_gusts_10m", "km/h"),
            "wind_direction": units.get("wind_direction_10m", "°"),
        },
        "summary": (
            f"{_weather_code_description(weather_code)}, "
            f"{current.get('temperature_2m')}°C, "
            f"wiatr {current.get('wind_speed_10m')} km/h, "
            f"ciśnienie {current.get('pressure_msl')} hPa."
        ),
    }


@mcp.tool(name="weather_hourly", description=_tool_description("weather_hourly"))
def weather_hourly(latitude: float, longitude: float, hours: int = 24) -> dict[str, Any]:
    safe_hours = max(1, min(int(hours), 168))
    payload = _fetch_forecast(
        {
            "latitude": latitude,
            "longitude": longitude,
            "forecast_hours": safe_hours,
            "hourly": DEFAULT_HOURLY_VARS,
        }
    )

    hourly = payload.get("hourly", {})
    units = payload.get("hourly_units", {})

    times = hourly.get("time", [])
    result_hours = []
    for i, time_value in enumerate(times[:safe_hours]):
        weather_code = int((hourly.get("weather_code") or [0])[i])
        visibility_m = (hourly.get("visibility") or [None])[i]
        visibility_km = round(visibility_m / 1000, 1) if isinstance(visibility_m, (int, float)) else None

        result_hours.append(
            {
                "time": time_value,
                "temperature_c": (hourly.get("temperature_2m") or [None])[i],
                "apparent_temperature_c": (hourly.get("apparent_temperature") or [None])[i],
                "relative_humidity_percent": (hourly.get("relative_humidity_2m") or [None])[i],
                "precipitation_probability_percent": (hourly.get("precipitation_probability") or [None])[i],
                "precipitation_mm": (hourly.get("precipitation") or [None])[i],
                "pressure_hpa": (hourly.get("pressure_msl") or [None])[i],
                "cloud_cover_percent": (hourly.get("cloud_cover") or [None])[i],
                "visibility_km": visibility_km,
                "wind_speed_kmh": (hourly.get("wind_speed_10m") or [None])[i],
                "wind_gusts_kmh": (hourly.get("wind_gusts_10m") or [None])[i],
                "wind_direction_deg": (hourly.get("wind_direction_10m") or [None])[i],
                "weather_code": weather_code,
                "weather_description": _weather_code_description(weather_code),
            }
        )

    return {
        **_location_payload(payload),
        "hours_requested": safe_hours,
        "units": {
            "temperature": units.get("temperature_2m", "°C"),
            "apparent_temperature": units.get("apparent_temperature", "°C"),
            "relative_humidity": units.get("relative_humidity_2m", "%"),
            "precipitation_probability": units.get("precipitation_probability", "%"),
            "precipitation": units.get("precipitation", "mm"),
            "pressure": units.get("pressure_msl", "hPa"),
            "cloud_cover": units.get("cloud_cover", "%"),
            "visibility": "km",
            "wind_speed": units.get("wind_speed_10m", "km/h"),
            "wind_gusts": units.get("wind_gusts_10m", "km/h"),
            "wind_direction": units.get("wind_direction_10m", "°"),
        },
        "hourly": result_hours,
    }


@mcp.tool(name="weather_daily", description=_tool_description("weather_daily"))
def weather_daily(latitude: float, longitude: float, days: int = 7) -> dict[str, Any]:
    safe_days = max(1, min(int(days), 16))
    payload = _fetch_forecast(
        {
            "latitude": latitude,
            "longitude": longitude,
            "forecast_days": safe_days,
            "daily": DEFAULT_DAILY_VARS,
        }
    )

    daily = payload.get("daily", {})
    units = payload.get("daily_units", {})
    dates = daily.get("time", [])

    result_days = []
    for i, date_value in enumerate(dates[:safe_days]):
        weather_code = int((daily.get("weather_code") or [0])[i])
        result_days.append(
            {
                "date": date_value,
                "temperature_min_c": (daily.get("temperature_2m_min") or [None])[i],
                "temperature_max_c": (daily.get("temperature_2m_max") or [None])[i],
                "precipitation_sum_mm": (daily.get("precipitation_sum") or [None])[i],
                "precipitation_probability_max_percent": (daily.get("precipitation_probability_max") or [None])[i],
                "wind_speed_max_kmh": (daily.get("wind_speed_10m_max") or [None])[i],
                "wind_gusts_max_kmh": (daily.get("wind_gusts_10m_max") or [None])[i],
                "sunrise": (daily.get("sunrise") or [None])[i],
                "sunset": (daily.get("sunset") or [None])[i],
                "weather_code": weather_code,
                "weather_description": _weather_code_description(weather_code),
            }
        )

    return {
        **_location_payload(payload),
        "days_requested": safe_days,
        "units": {
            "temperature_min": units.get("temperature_2m_min", "°C"),
            "temperature_max": units.get("temperature_2m_max", "°C"),
            "precipitation_sum": units.get("precipitation_sum", "mm"),
            "precipitation_probability_max": units.get("precipitation_probability_max", "%"),
            "wind_speed_max": units.get("wind_speed_10m_max", "km/h"),
            "wind_gusts_max": units.get("wind_gusts_10m_max", "km/h"),
        },
        "daily": result_days,
    }


@mcp.tool(name="geocode_city", description=_tool_description("geocode_city"))
def geocode_city(name: str, count: int = 5, language: str = "pl", country_code: str = "") -> dict[str, Any]:
    payload = _fetch_geocoding(name=name, count=count, language=language, country_code=country_code)
    results = []
    for item in payload.get("results", []) or []:
        results.append(
            {
                "name": item.get("name"),
                "country": item.get("country"),
                "country_code": item.get("country_code"),
                "admin1": item.get("admin1"),
                "admin2": item.get("admin2"),
                "latitude": item.get("latitude"),
                "longitude": item.get("longitude"),
                "timezone": item.get("timezone"),
                "elevation_m": item.get("elevation"),
            }
        )

    return {
        "query": name,
        "count": len(results),
        "results": results,
    }


@mcp.tool(name="weather_by_city", description=_tool_description("weather_by_city"))
def weather_by_city(city: str, country_code: str = "", language: str = "pl") -> dict[str, Any]:
    geocoded = _fetch_geocoding(name=city, count=1, language=language, country_code=country_code)
    results = geocoded.get("results", []) or []
    if not results:
        return {"error": "Nie znaleziono lokalizacji"}

    best = results[0]
    current = weather_current(latitude=float(best["latitude"]), longitude=float(best["longitude"]))
    current["location"] = {
        "name": best.get("name"),
        "country": best.get("country"),
        "country_code": best.get("country_code"),
        "admin1": best.get("admin1"),
        "admin2": best.get("admin2"),
    }
    return current


@mcp.tool(name="server_info_weather", description=_tool_description("server_info_weather"))
def server_info_weather() -> dict[str, Any]:
    local_ip = _detect_local_ip()
    return {
        "project_name": PROJECT_NAME,
        "base_dir": str(BASE_DIR),
        "mcp_endpoint_local": f"http://127.0.0.1:{MCP_PORT}/mcp",
        "mcp_endpoint_lan": f"http://{local_ip}:{MCP_PORT}/mcp",
        "timezone": DEFAULT_TIMEZONE,
        "tool_language": TOOL_LANGUAGE if TOOL_LANGUAGE in SUPPORTED_TOOL_LANGUAGES else "en",
        "provider": "Open-Meteo",
        "units": {
            "temperature": "°C",
            "wind_speed": "km/h",
            "pressure": "hPa",
            "visibility": "km",
            "precipitation": "mm",
        },
        "tools": [
            "weather_current",
            "weather_hourly",
            "weather_daily",
            "geocode_city",
            "weather_by_city",
            "server_info_weather",
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
