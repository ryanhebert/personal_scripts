#!/bin/bash
# Description: Screen session + Python venv auto-configuration for SSH logins

# ╔════════════════════════════════════════════════════════════════════════════╗
# ║  SSH Login Environment                                                     ║
# ║  Sourced by .bashrc — manages screen sessions & Python venv                ║
# ║  Zero network calls. <1 second startup.                                    ║
# ╚════════════════════════════════════════════════════════════════════════════╝

# Guard: non-interactive shells
[[ $- != *i* ]] && return 2>/dev/null

# Guard: don't run when executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This script should be sourced, not executed directly."
    echo "Add to your .bashrc:  source $(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    exit 1
fi

# --- DEFAULT CONFIGURATION ---
BASE_DIR="$HOME/ai"
VENV_DIR="$BASE_DIR/venv"
SCREEN_NAME="ssh"
ATTACH_TIMEOUT=3
REQUIREMENTS_FILE="$BASE_DIR/requirements.txt"
LOCK_DIR="/tmp/onboard-$(id -u)"
LOCK_FILE="$LOCK_DIR/onboard.lock"
SSH_SOCK_STABLE="$HOME/.ssh/ssh_auth_sock"

# --- USER OVERRIDES ---
ONBOARD_RC="$HOME/.onboardrc"
if [[ -f "$ONBOARD_RC" ]]; then
    # shellcheck source=/dev/null
    source "$ONBOARD_RC"
fi

# ── Colors ────────────────────────────────────────────────────────────────────

C_RESET="\033[0m"
C_BOLD="\033[1m"
C_DIM="\033[2m"
C_GREEN="\033[38;5;114m"
C_BLUE="\033[38;5;75m"
C_YELLOW="\033[38;5;221m"
C_RED="\033[38;5;203m"
C_CYAN="\033[38;5;117m"
C_GRAY="\033[38;5;245m"
C_WHITE="\033[38;5;255m"
C_MAGENTA="\033[38;5;176m"
C_ORANGE="\033[38;5;209m"

# ── Symbols ───────────────────────────────────────────────────────────────────

SYM_CHECK="✔"
SYM_CROSS="✖"
SYM_ARROW="▶"
SYM_GEAR="⚙"
SYM_SCREEN="◉"
SYM_DOTS="···"
SYM_LINE="─"
SYM_WARN="⚠"
SYM_LOCK="🔒"
SYM_PYTHON="🐍"
SYM_GIT="⎇"

# ── UI Helpers ────────────────────────────────────────────────────────────────

_hr() {
    local width=62 line=""
    for ((i = 0; i < width; i++)); do line+="$SYM_LINE"; done
    echo -e "${C_GRAY}${line}${C_RESET}"
}

_banner() {
    echo ""
    _hr
    echo -e "${C_BOLD}${C_BLUE}  ${SYM_SCREEN}  SSH Environment${C_RESET}"
    echo -e "${C_GRAY}     Screen + Python venv, auto-configured${C_RESET}"
    _hr
}

_step() {
    local symbol="$1" color="$2" message="$3"
    echo -e "  ${color}${symbol}${C_RESET}  ${C_WHITE}${message}${C_RESET}"
}

_step_ok()   { _step "$SYM_CHECK" "$C_GREEN"   "$1"; }
_step_warn() { _step "$SYM_WARN"  "$C_YELLOW"  "$1"; }
_step_fail() { _step "$SYM_CROSS" "$C_RED"     "$1"; }
_step_info() { _step "$SYM_GEAR"  "$C_CYAN"    "$1"; }
_step_dim()  { _step "$SYM_DOTS"  "$C_GRAY"    "$1"; }

# ── Core Functions ────────────────────────────────────────────────────────────

_check_root() {
    if [[ "$EUID" -eq 0 ]]; then
        _step_warn "Running as ${C_RED}root${C_RESET} — not recommended"
        _step_dim  "Screen sessions and venvs should be per-user"
        echo ""
        printf "  ${C_YELLOW}${SYM_ARROW}${C_RESET}  ${C_WHITE}Continue as root? ${C_DIM}[y/N]${C_RESET} "
        read -rsn1 -t 5 answer
        echo ""
        if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
            _step_info "Aborted. Login as a regular user."
            return 1
        fi
    fi
    return 0
}

_preserve_ssh_agent() {
    if [[ -n "$SSH_AUTH_SOCK" && "$SSH_AUTH_SOCK" != "$SSH_SOCK_STABLE" ]]; then
        mkdir -p "$(dirname "$SSH_SOCK_STABLE")" 2>/dev/null
        ln -sf "$SSH_AUTH_SOCK" "$SSH_SOCK_STABLE" 2>/dev/null
        export SSH_AUTH_SOCK="$SSH_SOCK_STABLE"
    fi
}

_cleanup_dead_screens() {
    local dead_count
    dead_count=$(screen -ls 2>/dev/null | grep -c "Dead")
    if [[ "$dead_count" -gt 0 ]]; then
        _step_warn "Cleaning up ${dead_count} dead screen session(s)${SYM_DOTS}"
        screen -wipe >/dev/null 2>&1
        _step_ok "Dead sessions removed"
    fi
}

_acquire_lock() {
    mkdir -p "$LOCK_DIR" 2>/dev/null
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if kill -0 "$lock_pid" 2>/dev/null; then
            _step_dim "Waiting for another onboard process (PID ${lock_pid})${SYM_DOTS}"
            local wait_count=0
            while [[ -f "$LOCK_FILE" ]] && kill -0 "$lock_pid" 2>/dev/null; do
                sleep 1
                ((wait_count++))
                if [[ "$wait_count" -ge 15 ]]; then
                    _step_warn "Lock timeout — proceeding"
                    break
                fi
            done
        else
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

_release_lock() {
    rm -f "$LOCK_FILE" 2>/dev/null
}

_countdown() {
    local seconds="$1"
    for ((i = seconds; i > 0; i--)); do
        printf "\r  ${C_YELLOW}${SYM_ARROW}${C_RESET}  ${C_WHITE}Auto-attaching in ${C_BOLD}${C_YELLOW}%d${C_RESET}${C_WHITE}s ${C_DIM}(press any key to cancel)${C_RESET}  " "$i"
        if read -rsn1 -t 1; then
            printf "\r%-72s\r" " "
            return 0   # key pressed = cancelled
        fi
    done
    printf "\r%-72s\r" " "
    return 1   # timeout = attach
}

_install_requirements() {
    if [[ ! -f "$REQUIREMENTS_FILE" ]]; then return; fi

    local HASH_FILE="$VENV_DIR/.requirements_hash"
    local CURRENT_HASH
    CURRENT_HASH=$(md5sum "$REQUIREMENTS_FILE" 2>/dev/null || md5 -q "$REQUIREMENTS_FILE" 2>/dev/null)

    if [[ -f "$HASH_FILE" ]] && [[ "$(cat "$HASH_FILE")" == "$CURRENT_HASH" ]]; then
        return
    fi

    _step_info "Installing Python requirements ${C_DIM}(${REQUIREMENTS_FILE})${C_RESET}"
    if pip install -q -r "$REQUIREMENTS_FILE" 2>/dev/null; then
        echo "$CURRENT_HASH" > "$HASH_FILE"
        _step_ok "Requirements installed"
    else
        _step_fail "Failed to install some requirements"
    fi
}

_sysinfo() {
    local py_ver uptime_str disk_usage load_avg

    py_ver=$(python3 --version 2>/dev/null | awk '{print $2}' || echo "N/A")

    if [[ "$OSTYPE" == "darwin"* ]]; then
        uptime_str=$(uptime | sed 's/.*up/up/' | sed 's/,.*//')
    else
        uptime_str=$(uptime -p 2>/dev/null || uptime | sed 's/.*up/up/' | sed 's/,.*//')
    fi

    disk_usage=$(df -h "$HOME" 2>/dev/null | awk 'NR==2 {printf "%s / %s (%s used)", $3, $2, $5}')

    if [[ "$OSTYPE" == "darwin"* ]]; then
        load_avg=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2, $3, $4}')
    else
        load_avg=$(awk '{print $1, $2, $3}' /proc/loadavg 2>/dev/null)
    fi

    echo ""
    echo -e "  ${C_GRAY}┌─ System ──────────────────────────────────────────────┐${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}  ${SYM_PYTHON} Python:   ${C_CYAN}${py_ver}${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}  ⏱  Uptime:   ${C_WHITE}${uptime_str}${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}  💾 Disk:     ${C_WHITE}${disk_usage}${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}  📊 Load:     ${C_WHITE}${load_avg}${C_RESET}"
    echo -e "  ${C_GRAY}└───────────────────────────────────────────────────────┘${C_RESET}"
}

ensure_dependencies() {
    # Only check outside screen — inside screen means we already passed this
    if [[ -n "$STY" ]]; then return; fi

    local NEED_SCREEN=0 NEED_PYTHON=0
    command -v screen  &>/dev/null || NEED_SCREEN=1
    command -v python3 &>/dev/null || NEED_PYTHON=1

    if [[ "$NEED_SCREEN" -eq 0 && "$NEED_PYTHON" -eq 0 ]]; then
        return 0
    fi

    _step_warn "Installing missing dependencies:"
    local pkgs=()
    [[ "$NEED_SCREEN" -eq 1 ]]  && pkgs+=("screen")  && _step_dim "  screen"
    [[ "$NEED_PYTHON" -eq 1 ]]  && pkgs+=("python3") && _step_dim "  python3"

    if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y -qq "${pkgs[@]}"
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y -q "${pkgs[@]}"
    elif command -v yum &>/dev/null; then
        sudo yum install -y -q "${pkgs[@]}"
    elif command -v brew &>/dev/null; then
        brew install "${pkgs[@]}"
    else
        _step_fail "No supported package manager found (apt/dnf/yum/brew)"
        return 1
    fi

    if [[ $? -eq 0 ]]; then
        _step_ok "Dependencies installed"
    else
        _step_fail "Failed to install some dependencies"
        return 1
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN: Screen Session Management
# ══════════════════════════════════════════════════════════════════════════════

# ── Outside Screen: auto-attach flow ─────────────────────────────────────────

if [[ -z "$STY" ]]; then
    _check_root || return
    mkdir -p "$BASE_DIR"
    _preserve_ssh_agent
    ensure_dependencies || return
    _cleanup_dead_screens

    local_existing=$(screen -ls 2>/dev/null | grep -c "$SCREEN_NAME")

    _banner
    echo ""

    if [[ "$local_existing" -gt 0 ]]; then
        _step_info "Existing session found: ${C_CYAN}${SCREEN_NAME}${C_RESET}"
    else
        _step_info "Creating new session: ${C_CYAN}${SCREEN_NAME}${C_RESET}"
    fi

    echo ""

    if _countdown "$ATTACH_TIMEOUT"; then
        echo ""
        _step_warn "Cancelled — normal shell session"
        _step_dim  "To attach manually:  ${C_CYAN}screen -dRR ${SCREEN_NAME}${C_RESET}"
        _hr
        echo ""
    else
        _step_ok "Attaching${SYM_DOTS}"
        echo ""
        exec screen -dRR "$SCREEN_NAME"
    fi
fi

# ── Inside Screen: venv + workspace setup ────────────────────────────────────

if [[ -n "$STY" && "$STY" == *"$SCREEN_NAME"* ]]; then
    _acquire_lock
    mkdir -p "$BASE_DIR"
    _preserve_ssh_agent

    # Create venv if missing
    if [[ ! -d "$VENV_DIR" ]]; then
        _banner
        echo ""
        _step_info "Building Python venv ${C_DIM}(one-time setup)${C_RESET}"
        if python3 -m venv "$VENV_DIR" 2>/dev/null; then
            _step_ok "Virtual environment created at ${C_CYAN}${VENV_DIR}${C_RESET}"
        else
            _step_fail "Failed to create venv — check python3-venv is installed"
        fi
        echo ""
        _hr
        echo ""
    fi

    # Activate venv
    if [[ -f "$VENV_DIR/bin/activate" ]]; then
        source "$VENV_DIR/bin/activate"
    fi

    _install_requirements
    _release_lock
    cd "$BASE_DIR" || true

    # Ensure 256-color support inside screen
    export TERM=screen-256color

    # Custom prompt
    export PS1="\[${C_RESET}\]\[${C_GREEN}\](venv)\[${C_RESET}\] \[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ "

    # Welcome banner — once per session
    if [[ -z "$_ONBOARD_WELCOMED" ]]; then
        export _ONBOARD_WELCOMED=1
        echo ""
        _banner
        echo ""
        _step_ok "Screen session:  ${C_CYAN}${SCREEN_NAME}${C_RESET}"
        _step_ok "Python venv:     ${C_CYAN}${VENV_DIR}${C_RESET}"
        _step_ok "Workspace:       ${C_CYAN}${BASE_DIR}${C_RESET}"

        if [[ -n "$SSH_AUTH_SOCK" ]]; then
            _step_ok "SSH Agent:       ${C_CYAN}forwarded${C_RESET}"
        else
            _step_dim "SSH Agent:       ${C_GRAY}not available${C_RESET}"
        fi

        _sysinfo

        echo ""
        _step_dim "Detach: ${C_WHITE}Ctrl-A D${C_RESET}${C_GRAY}  │  New window: ${C_WHITE}Ctrl-A C${C_RESET}${C_GRAY}  │  List: ${C_WHITE}Ctrl-A \"${C_RESET}"
        _hr
        echo ""
    fi
fi
