#!/usr/bin/env bash
# ======================================================================
#  rag-restart.sh – Multimodal Local RAG Orchestrator
# ----------------------------------------------------------------------
#  Steuert Reinhards lokalen RAG-Stack:
#    • Native Ollama (Mac, Metal-GPU) mit Flash Attention + KV-Cache q8_0
#    • Docker-Stack (n8n, postgres, qdrant, open-webui)
#    • Natives FastAPI-Backend (in eigenem Terminal-Tab)
#
#  Performance-Modi (ab v2):
#    OLLAMA_FLASH_ATTENTION=1   → Flash Attention 2 (~20-30% schneller)
#    OLLAMA_KV_CACHE_TYPE=q8_0  → KV-Cache 8-Bit (~50% weniger VRAM für Context)
#
#  Usage:
#    ./rag-restart.sh             Voller Neustart (Standard)
#    ./rag-restart.sh --status    Nur Status anzeigen
#    ./rag-restart.sh --stop      Alles sauber runterfahren
#    ./rag-restart.sh --no-backend  Backend nicht automatisch starten
#    ./rag-restart.sh --help      Diese Hilfe anzeigen
# ======================================================================

set -euo pipefail

# ---------- Konfiguration -----------------------------------------------
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="docker-compose.dev.yml"
LOG_FILE="${HOME}/rag-restart.log"

OLLAMA_HOST="http://localhost:11434"
LLM_MODEL="qwen3:4b-instruct-2507-q4_K_M"
EMBED_MODEL="qllama/multilingual-e5-large-instruct:latest"

BACKEND_DIR="${REPO_DIR}/backend"
BACKEND_PORT="5008"
BACKEND_CMD="uv run uvicorn src.main:app --reload --port ${BACKEND_PORT}"

# Performance-Schalter für Ollama (ab Ollama 0.21.x)
# Per Umgebungsvariable überschreibbar, falls jemand sie deaktivieren möchte.
OLLAMA_FLASH_ATTENTION="${OLLAMA_FLASH_ATTENTION:-1}"
OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-q8_0}"

# ---------- Farben ------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET='\033[0m'
    C_BOLD='\033[1m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_RED='\033[0;31m'
    C_BLUE='\033[0;34m'
    C_GRAY='\033[0;90m'
else
    C_RESET='' C_BOLD='' C_GREEN='' C_YELLOW='' C_RED='' C_BLUE='' C_GRAY=''
fi

# ---------- Logging-Helfer ---------------------------------------------
log()  { printf "${C_GRAY}[%s]${C_RESET} %s\n" "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
info() { printf "${C_BLUE}ℹ${C_RESET}  %s\n" "$*"; log "INFO: $*" >/dev/null; }
ok()   { printf "${C_GREEN}✓${C_RESET}  %s\n" "$*"; log "OK:   $*" >/dev/null; }
warn() { printf "${C_YELLOW}⚠${C_RESET}  %s\n" "$*"; log "WARN: $*" >/dev/null; }
err()  { printf "${C_RED}✗${C_RESET}  %s\n" "$*" >&2; log "ERR:  $*" >/dev/null; }
step() { printf "\n${C_BOLD}${C_BLUE}▸ %s${C_RESET}\n" "$*"; log "STEP: $*" >/dev/null; }

# ---------- Hilfsfunktionen --------------------------------------------
require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        err "Befehl nicht gefunden: $1"
        exit 1
    fi
}

wait_for_port() {
    local host="$1" port="$2" timeout="${3:-30}" name="${4:-service}"
    local start=$SECONDS
    while ! nc -z "$host" "$port" 2>/dev/null; do
        if (( SECONDS - start >= timeout )); then
            err "Timeout: ${name} auf ${host}:${port} nicht erreichbar"
            return 1
        fi
        sleep 1
    done
    ok "${name} bereit (${host}:${port})"
}

# ---------- Schritt 1: Docker-Stack stoppen -----------------------------
stop_docker_stack() {
    step "Docker-Stack stoppen"
    if ! docker info >/dev/null 2>&1; then
        warn "Docker läuft nicht – überspringe"
        return 0
    fi
    cd "$REPO_DIR"
    if docker compose -f "$COMPOSE_FILE" ps -q 2>/dev/null | grep -q .; then
        docker compose -f "$COMPOSE_FILE" down
        ok "Docker-Services gestoppt"
    else
        info "Keine laufenden Services im Compose-Stack"
    fi
}

# ---------- Schritt 2: Natives Ollama beenden --------------------------
stop_ollama() {
    step "Natives Ollama beenden"
    local pids
    pids=$(pgrep -x ollama || true)
    if [[ -z "$pids" ]]; then
        info "Ollama läuft nicht"
        return 0
    fi
    info "Beende Ollama-Prozesse: $pids"
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true
    sleep 2
    pids=$(pgrep -x ollama || true)
    if [[ -n "$pids" ]]; then
        warn "Erzwinge Beenden (kill -9)"
        # shellcheck disable=SC2086
        kill -9 $pids 2>/dev/null || true
        sleep 1
    fi
    if pgrep -x ollama >/dev/null; then
        err "Ollama lässt sich nicht beenden"
        return 1
    fi
    ok "Ollama beendet"
}

# ---------- Schritt 3: Backend beenden ---------------------------------
stop_backend() {
    step "Backend (uvicorn) beenden"
    local pids
    pids=$(pgrep -f "uvicorn src.main:app" || true)
    if [[ -z "$pids" ]]; then
        info "Backend läuft nicht"
        return 0
    fi
    info "Beende Backend-Prozesse: $pids"
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true
    sleep 2
    pids=$(pgrep -f "uvicorn src.main:app" || true)
    if [[ -n "$pids" ]]; then
        # shellcheck disable=SC2086
        kill -9 $pids 2>/dev/null || true
    fi
    ok "Backend beendet"
}

# ---------- Schritt 4: Ollama nativ starten ----------------------------
start_ollama() {
    step "Natives Ollama starten (mit Performance-Schaltern)"
    info "OLLAMA_KEEP_ALIVE=-1 (Modelle bleiben dauerhaft warm)"
    info "OLLAMA_FLASH_ATTENTION=${OLLAMA_FLASH_ATTENTION} (Flash Attention 2)"
    info "OLLAMA_KV_CACHE_TYPE=${OLLAMA_KV_CACHE_TYPE} (KV-Cache-Quantisierung)"

    launchctl setenv OLLAMA_KEEP_ALIVE -1
    launchctl setenv OLLAMA_FLASH_ATTENTION "${OLLAMA_FLASH_ATTENTION}"
    launchctl setenv OLLAMA_KV_CACHE_TYPE "${OLLAMA_KV_CACHE_TYPE}"

    OLLAMA_KEEP_ALIVE=-1 \
    OLLAMA_FLASH_ATTENTION="${OLLAMA_FLASH_ATTENTION}" \
    OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE}" \
        nohup ollama serve >> "${HOME}/ollama.log" 2>&1 &
    disown
    sleep 2
    wait_for_port localhost 11434 15 "Ollama-Server"
}

# ---------- Schritt 5: Modelle vorladen --------------------------------
preload_models() {
    step "Modelle vorladen (keep_alive: -1)"

    info "Lade LLM: ${LLM_MODEL}"
    curl -sS "${OLLAMA_HOST}/api/generate" \
        -d "{\"model\":\"${LLM_MODEL}\",\"keep_alive\":-1}" \
        >/dev/null
    ok "${LLM_MODEL} vorgeladen"

    info "Lade Embedding: ${EMBED_MODEL}"
    curl -sS "${OLLAMA_HOST}/api/embeddings" \
        -d "{\"model\":\"${EMBED_MODEL}\",\"prompt\":\"warmup\",\"keep_alive\":-1}" \
        >/dev/null
    ok "${EMBED_MODEL} vorgeladen"
}

# ---------- Schritt 6: Docker-Stack starten ----------------------------
start_docker_stack() {
    step "Docker-Stack starten (${COMPOSE_FILE})"
    cd "$REPO_DIR"
    docker compose -f "$COMPOSE_FILE" up -d
    ok "Container gestartet"

    info "Warte auf Postgres ..."
    wait_for_port localhost 5436 30 "Postgres" || true
    info "Warte auf Qdrant ..."
    wait_for_port localhost 6333 30 "Qdrant" || true
    info "Warte auf n8n ..."
    wait_for_port localhost 5678 30 "n8n" || true
    info "Warte auf Open WebUI ..."
    wait_for_port localhost 3000 30 "Open WebUI" || true
}

# ---------- Schritt 7: Backend in neuem Tab ----------------------------
start_backend_tab() {
    step "Backend in neuem Terminal-Tab starten"
    if [[ ! -d "$BACKEND_DIR" ]]; then
        err "Backend-Verzeichnis nicht gefunden: $BACKEND_DIR"
        return 1
    fi
    if ! command -v uv >/dev/null 2>&1; then
        warn "uv nicht gefunden – Backend muss manuell gestartet werden"
        info "  cd ${BACKEND_DIR} && ${BACKEND_CMD}"
        return 0
    fi

    # Erkenne, welches Terminal aktiv ist
    local term_app="${TERM_PROGRAM:-Apple_Terminal}"
    local cmd="cd '${BACKEND_DIR}' && ${BACKEND_CMD}"

    case "$term_app" in
        iTerm.app)
            osascript <<EOF
tell application "iTerm"
    tell current window
        create tab with default profile
        tell current session of current tab
            write text "${cmd}"
        end tell
    end tell
end tell
EOF
            ok "Backend-Tab in iTerm geöffnet"
            ;;
        Apple_Terminal)
            osascript <<EOF
tell application "Terminal"
    activate
    tell application "System Events" to keystroke "t" using command down
    delay 0.5
    do script "${cmd}" in front window
end tell
EOF
            ok "Backend-Tab in Terminal.app geöffnet"
            ;;
        vscode)
            warn "VS Code Terminal erkannt – kann keinen neuen Tab öffnen"
            info "Bitte Backend manuell in neuem Terminal-Tab starten:"
            info "  cd ${BACKEND_DIR} && ${BACKEND_CMD}"
            ;;
        *)
            warn "Unbekanntes Terminal: ${term_app}"
            info "Backend manuell starten:"
            info "  cd ${BACKEND_DIR} && ${BACKEND_CMD}"
            ;;
    esac
}

# ---------- Status-Anzeige ---------------------------------------------
show_status() {
    step "Status"
    printf "\n${C_BOLD}Ollama-Modelle:${C_RESET}\n"
    if pgrep -x ollama >/dev/null; then
        ollama ps 2>/dev/null || warn "ollama ps fehlgeschlagen"
        printf "\n${C_BOLD}Performance-Modus:${C_RESET}\n"
        local fa kv
        fa=$(launchctl getenv OLLAMA_FLASH_ATTENTION 2>/dev/null || echo "nicht gesetzt")
        kv=$(launchctl getenv OLLAMA_KV_CACHE_TYPE 2>/dev/null || echo "nicht gesetzt")
        printf "  Flash Attention:  ${C_GREEN}%s${C_RESET}\n" "$fa"
        printf "  KV-Cache-Type:    ${C_GREEN}%s${C_RESET}\n" "$kv"
    else
        warn "Ollama läuft nicht"
    fi

    printf "\n${C_BOLD}Docker-Services:${C_RESET}\n"
    if docker info >/dev/null 2>&1; then
        cd "$REPO_DIR"
        docker compose -f "$COMPOSE_FILE" ps 2>/dev/null || warn "Compose-Status fehlgeschlagen"
    else
        warn "Docker läuft nicht"
    fi

    printf "\n${C_BOLD}Backend (Port ${BACKEND_PORT}):${C_RESET}\n"
    if pgrep -f "uvicorn src.main:app" >/dev/null; then
        ok "Backend läuft (PID: $(pgrep -f 'uvicorn src.main:app' | tr '\n' ' '))"
    else
        warn "Backend läuft nicht"
    fi

    printf "\n${C_BOLD}Endpoints:${C_RESET}\n"
    printf "  ${C_GREEN}Open WebUI${C_RESET}   http://localhost:3000\n"
    printf "  ${C_GREEN}n8n${C_RESET}          http://localhost:5678\n"
    printf "  ${C_GREEN}Qdrant${C_RESET}       http://localhost:6333/dashboard\n"
    printf "  ${C_GREEN}Backend${C_RESET}      http://localhost:${BACKEND_PORT}/docs\n"
    printf "  ${C_GREEN}Ollama${C_RESET}       http://localhost:11434\n"
}

# ---------- Main --------------------------------------------------------
usage() {
    sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
    local mode="restart"
    local start_backend="yes"

    for arg in "$@"; do
        case "$arg" in
            --status)      mode="status" ;;
            --stop)        mode="stop" ;;
            --no-backend)  start_backend="no" ;;
            --help|-h)     usage; exit 0 ;;
            *) err "Unbekanntes Argument: $arg"; usage; exit 1 ;;
        esac
    done

    require_cmd docker
    require_cmd ollama
    require_cmd curl
    require_cmd nc

    printf "${C_BOLD}━━━ Multimodal RAG – %s ━━━${C_RESET}\n" "$(echo "$mode" | tr "[:lower:]" "[:upper:]")"
    log "=== Run started: mode=${mode} backend=${start_backend} ==="

    case "$mode" in
        status)
            show_status
            ;;
        stop)
            stop_backend
            stop_docker_stack
            stop_ollama
            ok "Alles heruntergefahren"
            ;;
        restart)
            stop_backend
            stop_docker_stack
            stop_ollama
            start_ollama
            preload_models
            start_docker_stack
            if [[ "$start_backend" == "yes" ]]; then
                start_backend_tab
            else
                info "Backend-Start übersprungen (--no-backend)"
            fi
            show_status
            printf "\n${C_GREEN}${C_BOLD}✓ RAG-Stack ist betriebsbereit${C_RESET}\n\n"
            ;;
    esac
}

main "$@"
