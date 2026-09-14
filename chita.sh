#!/usr/bin/env bash
#
# chita.sh — launcher de los procesos de Chita
#
#   ./chita.sh start    [proc...]   arranca (en orden, esperando readiness)
#   ./chita.sh stop     [proc...]   detiene (orden inverso, TERM -> KILL)
#   ./chita.sh restart  [proc...]   stop + start
#   ./chita.sh status               tabla de estado
#   ./chita.sh logs     [proc]      tail -f de los logs
#   ./chita.sh doctor               chequeos previos al arranque
#
# Procesos: prolog (8000)  a2a (8001)  kafka (8090)  flask (8070)
#
# Config por entorno:
#   CHITA_PROVIDER       proveedor LLM de start_server/2   (default: openai)
#   PROLOG_PORT          puerto del chatbot Prolog          (default: 8000)
#   PROLOG_READY_TIMEOUT segundos de espera del Prolog      (default: 90)
#   PY_READY_TIMEOUT     segundos de espera de los Flask    (default: 25)
#   STOP_GRACE           segundos antes del SIGKILL         (default: 10)
#
set -euo pipefail

# ── El chatbot usa paths relativos ('.env', 'tramites/', 'chatbot.db',
#    'pregunta_cache.pl', 'static/'), así que todo corre desde la raíz del repo.
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

RUN_DIR="$ROOT_DIR/run"
LOG_DIR="$ROOT_DIR/logs"
LOG_MAX_BYTES=$((10 * 1024 * 1024))

CHITA_PROVIDER="${CHITA_PROVIDER:-openai}"
PROLOG_PORT="${PROLOG_PORT:-8000}"
PROLOG_READY_TIMEOUT="${PROLOG_READY_TIMEOUT:-90}"
PY_READY_TIMEOUT="${PY_READY_TIMEOUT:-25}"
STOP_GRACE="${STOP_GRACE:-10}"

# El puerto A2A lo decide el propio chita_a2a_server.py leyendo .env.
A2A_PORT="$(sed -n 's/^[[:space:]]*A2A_BRIDGE_PORT[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p' .env 2>/dev/null | tail -1)"
A2A_PORT="${A2A_PORT:-8001}"

# Los puertos de flask y kafka están hardcodeados en los .py; acá sólo se usan
# para el health-check. Si los cambiás en el fuente, cambialos también acá.
FLASK_PORT=8070
KAFKA_PORT=8090

# Orden de arranque. El stop recorre esta lista al revés.
PROCS=(prolog a2a kafka flask)

# ──────────────────────────────────────────────────────────────────────────────
# Colores
# ──────────────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[34m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_DIM=''; C_RST=''
fi

info() { printf '%s==>%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s ok %s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s -- %s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
err()  { printf '%s!!! %s %s\n' "$C_RED" "$C_RST" "$*" >&2; }

# ──────────────────────────────────────────────────────────────────────────────
# Descripción de cada proceso
# ──────────────────────────────────────────────────────────────────────────────

proc_port() {
    case "$1" in
        prolog) echo "$PROLOG_PORT" ;;
        a2a)    echo "$A2A_PORT" ;;
        kafka)  echo "$KAFKA_PORT" ;;
        flask)  echo "$FLASK_PORT" ;;
    esac
}

proc_desc() {
    case "$1" in
        prolog) echo "chatbot.pl (motor de diálogo)" ;;
        a2a)    echo "chita_a2a_server.py (bridge A2A)" ;;
        kafka)  echo "kafka_bridge.py (puente Kafka)" ;;
        flask)  echo "flask_cloud_api_proxy.py (proxy WhatsApp)" ;;
    esac
}

proc_file() {
    case "$1" in
        prolog) echo "chatbot.pl" ;;
        a2a)    echo "chita_a2a_server.py" ;;
        kafka)  echo "kafka_bridge.py" ;;
        flask)  echo "flask_cloud_api_proxy.py" ;;
    esac
}

# Marca que identifica al proceso dentro de /proc/<pid>/cmdline. Sirve para no
# mandarle señales a un PID reciclado por otro programa.
proc_marker() { proc_file "$1"; }

# Timeout de readiness según el proceso. Prolog tarda más: start_server/2 carga
# trámites desde dos APIs remotas ANTES de abrir el puerto.
proc_timeout() {
    case "$1" in
        prolog) echo "$PROLOG_READY_TIMEOUT" ;;
        *)      echo "$PY_READY_TIMEOUT" ;;
    esac
}

# Comando de arranque, como array, en la variable nombrada CMD.
#
# Nota Prolog: '-t halt' a secas NO alcanza. http_server/2 devuelve el control
# apenas levanta los threads de accept, entonces el toplevel corre halt y mata
# el servidor al instante. El '-g thread_get_message(_)' bloquea el hilo main
# para siempre (y sigue respondiendo a SIGTERM).
# El set_stream/2 fuerza line buffering para que el log se vea en vivo.
build_cmd() {
    case "$1" in
        prolog)
            CMD=(swipl -q
                 -g "set_stream(user_output,buffer(line))"
                 -g "set_stream(user_error,buffer(line))"
                 -g "start_server($CHITA_PROVIDER,$PROLOG_PORT)"
                 -g "thread_get_message(_)"
                 -t halt
                 chatbot.pl)
            ;;
        # -u => stdout/stderr sin buffer, si no los logs salen a los 8 KB.
        a2a)   CMD=(python3 -u chita_a2a_server.py) ;;
        kafka) CMD=(python3 -u kafka_bridge.py) ;;
        flask) CMD=(python3 -u flask_cloud_api_proxy.py) ;;
    esac
}

pid_file() { echo "$RUN_DIR/$1.pid"; }
log_file() { echo "$LOG_DIR/$1.log"; }

# ──────────────────────────────────────────────────────────────────────────────
# Primitivas de proceso / red
# ──────────────────────────────────────────────────────────────────────────────

# ¿El PID está vivo Y es realmente nuestro proceso?
pid_alive() {
    local pid="$1" marker="$2"
    [[ -n "$pid" ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    [[ -r "/proc/$pid/cmdline" ]] || return 1
    tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF -- "$marker"
}

# PID registrado y verificado, o vacío.
current_pid() {
    local proc="$1" pf pid
    pf="$(pid_file "$proc")"
    [[ -f "$pf" ]] || return 0
    pid="$(cat "$pf" 2>/dev/null || true)"
    if pid_alive "$pid" "$(proc_marker "$proc")"; then
        echo "$pid"
    fi
}

# ¿Hay algo escuchando en el puerto? Bash puro, sin nc/lsof.
port_open() {
    local port="$1"
    (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && exec 3>&- && return 0
    return 1
}

# PID del dueño del puerto, si se puede averiguar (mejor esfuerzo).
port_owner_pid() {
    local port="$1"
    command -v ss >/dev/null 2>&1 || return 0
    ss -ltnp "sport = :$port" 2>/dev/null |
        sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | head -1
}

# Readiness: puerto abierto y, donde exista, endpoint HTTP respondiendo.
is_ready() {
    local proc="$1" port
    port="$(proc_port "$proc")"
    port_open "$port" || return 1
    case "$proc" in
        a2a)
            curl -fsS --max-time 3 "http://127.0.0.1:$port/health" >/dev/null 2>&1
            ;;
        prolog)
            curl -fsS --max-time 5 "http://127.0.0.1:$port/.well-known/agent.json" >/dev/null 2>&1
            ;;
        *) return 0 ;;
    esac
}

uptime_of() {
    local pid="$1" start now
    start="$(stat -c %Y "/proc/$pid" 2>/dev/null || echo '')"
    [[ -n "$start" ]] || { echo '-'; return; }
    now="$(date +%s)"
    local s=$((now - start))
    if   (( s < 60 ));   then echo "${s}s"
    elif (( s < 3600 )); then echo "$((s / 60))m"
    elif (( s < 86400 ));then echo "$((s / 3600))h$(( (s % 3600) / 60 ))m"
    else                      echo "$((s / 86400))d$(( (s % 86400) / 3600 ))h"
    fi
}

rotate_log() {
    local lf="$1" size
    [[ -f "$lf" ]] || return 0
    size="$(stat -c %s "$lf" 2>/dev/null || echo 0)"
    if (( size > LOG_MAX_BYTES )); then
        mv -f "$lf" "$lf.1"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# start / stop
# ──────────────────────────────────────────────────────────────────────────────

start_one() {
    local proc="$1" pid port lf pf owner waited timeout
    port="$(proc_port "$proc")"
    pf="$(pid_file "$proc")"
    lf="$(log_file "$proc")"

    pid="$(current_pid "$proc")"
    if [[ -n "$pid" ]]; then
        ok "$proc ya está corriendo (pid $pid, puerto $port)"
        return 0
    fi

    # PID file huérfano: el proceso murió sin limpiar.
    if [[ -f "$pf" ]]; then
        warn "$proc: descartando pid file obsoleto ($(cat "$pf" 2>/dev/null))"
        rm -f "$pf"
    fi

    # El puerto está tomado por alguien que no somos nosotros.
    if port_open "$port"; then
        owner="$(port_owner_pid "$port")"
        err "$proc: el puerto $port ya está ocupado${owner:+ por el pid $owner}"
        err "     revisá con: ss -ltnp sport = :$port"
        return 1
    fi

    build_cmd "$proc"
    rotate_log "$lf"
    {
        echo
        echo "=== start $(date -Is) :: ${CMD[*]} ==="
    } >> "$lf"

    # setsid: sesión propia, para que un Ctrl-C en esta terminal no lo tumbe.
    # </dev/null: si no, un servidor en background que lea stdin recibe SIGTTIN.
    setsid nohup "${CMD[@]}" < /dev/null >> "$lf" 2>&1 &
    pid=$!
    echo "$pid" > "$pf"

    timeout="$(proc_timeout "$proc")"
    printf '%s==>%s %s arrancando (pid %s, puerto %s) ' "$C_BLU" "$C_RST" "$proc" "$pid" "$port"
    waited=0
    while (( waited < timeout )); do
        if is_ready "$proc"; then
            printf '\n'
            # Con el swipl de flatpak, el PID lanzado ($!) es sólo un wrapper
            # bash -> flatpak -> bwrap -> swipl: si le llega la señal, muere el
            # wrapper y el servidor queda huérfano con el puerto tomado. El
            # proceso que realmente escucha es el dueño del puerto; guardamos
            # ese PID para que stop/status/restart operen sobre el correcto.
            # Para los .py el dueño del puerto y $! son el mismo proceso.
            local real
            real="$(port_owner_pid "$port")"
            if [[ -n "$real" ]] && pid_alive "$real" "$(proc_marker "$proc")"; then
                echo "$real" > "$pf"
                pid="$real"
            fi
            ok "$proc listo en el puerto $port (pid $pid) ${C_DIM}($(proc_desc "$proc"))${C_RST}"
            return 0
        fi
        # Si el proceso se murió, no tiene sentido seguir esperando.
        if ! pid_alive "$pid" "$(proc_marker "$proc")"; then
            printf '\n'
            err "$proc murió durante el arranque. Últimas líneas de $lf:"
            tail -n 20 "$lf" >&2 || true
            rm -f "$pf"
            return 1
        fi
        printf '.'
        sleep 1
        waited=$((waited + 1))
    done

    printf '\n'
    err "$proc no quedó listo tras ${timeout}s. Últimas líneas de $lf:"
    tail -n 20 "$lf" >&2 || true
    return 1
}

stop_one() {
    local proc="$1" pid pf waited
    pf="$(pid_file "$proc")"
    pid="$(current_pid "$proc")"

    if [[ -z "$pid" ]]; then
        if [[ -f "$pf" ]]; then
            warn "$proc: no estaba corriendo, limpio el pid file"
            rm -f "$pf"
        else
            printf '%s -- %s %s ya estaba detenido\n' "$C_DIM" "$C_RST" "$proc"
        fi
        return 0
    fi

    info "deteniendo $proc (pid $pid)"
    kill -TERM "$pid" 2>/dev/null || true

    waited=0
    while (( waited < STOP_GRACE )); do
        pid_alive "$pid" "$(proc_marker "$proc")" || break
        sleep 1
        waited=$((waited + 1))
    done

    if pid_alive "$pid" "$(proc_marker "$proc")"; then
        warn "$proc no respondió a SIGTERM, mando SIGKILL"
        kill -KILL "$pid" 2>/dev/null || true
        sleep 1
    fi

    rm -f "$pf"
    ok "$proc detenido"
}

# ──────────────────────────────────────────────────────────────────────────────
# Comandos
# ──────────────────────────────────────────────────────────────────────────────

cmd_start() {
    local targets=("$@") failed=0
    (( ${#targets[@]} )) || targets=("${PROCS[@]}")
    mkdir -p "$RUN_DIR" "$LOG_DIR"
    for proc in "${targets[@]}"; do
        if ! start_one "$proc"; then
            failed=1
            err "abortando: $proc no arrancó (los que ya subieron siguen en pie)"
            break
        fi
    done
    echo
    cmd_status
    return $failed
}

cmd_stop() {
    local targets=("$@") reversed=()
    if (( ${#targets[@]} )); then
        reversed=("${targets[@]}")
    else
        # Orden inverso al de arranque.
        for (( i = ${#PROCS[@]} - 1; i >= 0; i-- )); do
            reversed+=("${PROCS[$i]}")
        done
    fi
    for proc in "${reversed[@]}"; do
        stop_one "$proc"
    done
}

cmd_restart() {
    local targets=("$@")
    cmd_stop "${targets[@]}"
    echo
    cmd_start "${targets[@]}"
}

cmd_status() {
    local proc pid port state upt
    printf '%-8s %-8s %-7s %-14s %-8s %s\n' PROCESO PID PUERTO ESTADO UPTIME DESCRIPCIÓN
    printf '%s\n' '----------------------------------------------------------------------------------'
    for proc in "${PROCS[@]}"; do
        port="$(proc_port "$proc")"
        pid="$(current_pid "$proc")"
        if [[ -n "$pid" ]]; then
            upt="$(uptime_of "$pid")"
            if is_ready "$proc"; then
                state="${C_GRN}up${C_RST}"
            else
                state="${C_YEL}arrancando${C_RST}"
            fi
        else
            pid='-'; upt='-'
            if [[ -f "$(pid_file "$proc")" ]]; then
                state="${C_RED}pid-obsoleto${C_RST}"
            elif port_open "$port"; then
                state="${C_RED}puerto-ajeno${C_RST}"
            else
                state="${C_DIM}down${C_RST}"
            fi
        fi
        # El padding se calcula sobre el texto sin códigos ANSI.
        local plain
        plain="$(printf '%s' "$state" | sed 's/\x1b\[[0-9;]*m//g')"
        local pad=$(( 14 - ${#plain} ))
        (( pad < 0 )) && pad=0
        printf '%-8s %-8s %-7s %s%*s %-8s %s\n' \
               "$proc" "$pid" "$port" "$state" "$pad" '' "$upt" "$(proc_desc "$proc")"
    done
}

cmd_logs() {
    local proc="${1:-}" files=()
    mkdir -p "$LOG_DIR"
    if [[ -n "$proc" ]]; then
        files=("$(log_file "$proc")")
    else
        for p in "${PROCS[@]}"; do files+=("$(log_file "$p")"); done
    fi
    for f in "${files[@]}"; do [[ -f "$f" ]] || : > "$f"; done
    info "tail -f (Ctrl-C para salir)"
    tail -n 30 -f "${files[@]}"
}

cmd_doctor() {
    local rc=0 port proc f

    info "binarios"
    for bin in swipl python3 curl; do
        if command -v "$bin" >/dev/null 2>&1; then
            ok "$bin -> $(command -v "$bin")"
        else
            err "falta $bin"; rc=1
        fi
    done

    echo; info "archivos fuente"
    for proc in "${PROCS[@]}"; do
        f="$(proc_file "$proc")"
        if [[ -f "$f" ]]; then ok "$f"; else err "falta $f"; rc=1; fi
    done

    echo; info ".env"
    if [[ -f .env ]]; then
        ok ".env presente"
        for key in META_VERIFY_TOKEN META_ACCESS_TOKEN META_PHONE_NUMBER_ID \
				     PROLOG_BASE_URL KAFKA_BRIDGE_URL FLASKURL; do
            if grep -qE "^[[:space:]]*$key[[:space:]]*=[[:space:]]*[^[:space:]]" .env; then
                ok "$key definida"
            else
                warn "$key falta o está vacía en .env"
            fi
        done
    else
        err "falta .env (chatbot.pl lo carga con load_dot_env/1 y los .py con load_dotenv())"
        rc=1
    fi

    echo; info "módulos de Python"
    for mod in flask kafka requests dotenv openai phonenumbers; do
        if python3 -c "import $mod" 2>/dev/null; then
            ok "$mod"
        else
            err "falta el módulo $mod (pip3 install $mod)"; rc=1
        fi
    done

    echo; info "puertos"
    for proc in "${PROCS[@]}"; do
        port="$(proc_port "$proc")"
        if port_open "$port"; then
            if [[ -n "$(current_pid "$proc")" ]]; then
                ok "$port en uso por $proc (ya corriendo)"
            else
                local owner; owner="$(port_owner_pid "$port")"
                err "$port ocupado por un proceso ajeno${owner:+ (pid $owner)}"; rc=1
            fi
        else
            ok "$port libre"
        fi
    done

    echo
    if (( rc == 0 )); then
        ok "todo en orden, podés correr: ./chita.sh start"
    else
        err "hay problemas que resolver antes de arrancar"
    fi
    return $rc
}

usage() {
    cat <<EOF
chita.sh — launcher de los procesos de Chita

Uso: ./chita.sh <comando> [proceso...]

Comandos:
  start   [proc...]   arranca en orden, esperando que cada uno quede listo
  stop    [proc...]   detiene en orden inverso (SIGTERM, luego SIGKILL)
  restart [proc...]   stop + start
  status              tabla de estado de los 4 procesos
  logs    [proc]      tail -f de los logs
  doctor              chequeos previos (binarios, .env, módulos, puertos)

Procesos: ${PROCS[*]}
  prolog  $(printf '%-5s' "$PROLOG_PORT") $(proc_desc prolog)
  a2a     $(printf '%-5s' "$A2A_PORT") $(proc_desc a2a)
  kafka   $(printf '%-5s' "$KAFKA_PORT") $(proc_desc kafka)
  flask   $(printf '%-5s' "$FLASK_PORT") $(proc_desc flask)

Ejemplos:
  ./chita.sh start              # levanta todo
  ./chita.sh restart prolog     # reinicia sólo el chatbot
  ./chita.sh logs flask         # sigue el log del proxy de WhatsApp

Entorno: CHITA_PROVIDER=$CHITA_PROVIDER PROLOG_PORT=$PROLOG_PORT
         PROLOG_READY_TIMEOUT=$PROLOG_READY_TIMEOUT PY_READY_TIMEOUT=$PY_READY_TIMEOUT
         STOP_GRACE=$STOP_GRACE
Estado:  $RUN_DIR
Logs:    $LOG_DIR
EOF
}

validate_procs() {
    local p found
    for p in "$@"; do
        found=0
        for known in "${PROCS[@]}"; do
            [[ "$p" == "$known" ]] && { found=1; break; }
        done
        if (( ! found )); then
            err "proceso desconocido: '$p' (válidos: ${PROCS[*]})"
            exit 2
        fi
    done
}

main() {
    local cmd="${1:-}"
    shift || true
    case "$cmd" in
        start)   validate_procs "$@"; cmd_start "$@" ;;
        stop)    validate_procs "$@"; cmd_stop "$@" ;;
        restart) validate_procs "$@"; cmd_restart "$@" ;;
        status)  cmd_status ;;
        logs)    [[ -n "${1:-}" ]] && validate_procs "$1"; cmd_logs "${1:-}" ;;
        doctor)  cmd_doctor ;;
        -h|--help|help|'') usage ;;
        *) err "comando desconocido: '$cmd'"; echo; usage; exit 2 ;;
    esac
}

main "$@"
