#!/bin/bash

# ╔════════════════════════════════════════════════════════════════════════════╗
# ║  SSH Onboarding Script  v4.0                                               ║
# ║  Auto-installs into shell profile, manages screen sessions & Python venv   ║
# ║  Self-updates from private GitHub repo with OAuth device flow              ║
# ╚════════════════════════════════════════════════════════════════════════════╝

ONBOARD_VERSION="4.0.0"

# --- DEFAULT CONFIGURATION ---
BASE_DIR="$HOME/ai"
VENV_DIR="$BASE_DIR/venv"
SCREEN_NAME="ssh"
ATTACH_TIMEOUT=3
REQUIREMENTS_FILE="$BASE_DIR/requirements.txt"
LOCK_DIR="/tmp/onboard-$(id -u)"
LOCK_FILE="$LOCK_DIR/onboard.lock"
SSH_SOCK_STABLE="$HOME/.ssh/ssh_auth_sock"
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# --- GITHUB / SELF-UPDATE CONFIGURATION ---
GITHUB_REPO="ryanhebert/personal_scripts"
GITHUB_BRANCH="main"
GITHUB_SCRIPT_PATH="onboard.sh"
GITHUB_API_URL="https://api.github.com/repos/${GITHUB_REPO}/commits?path=${GITHUB_SCRIPT_PATH}&per_page=1&sha=${GITHUB_BRANCH}"
UPDATE_CHECK_INTERVAL=86400  # Check once per day (seconds)
UPDATE_HASH_FILE="$HOME/.onboard_last_update"

# --- OAUTH DEVICE FLOW CONFIGURATION ---
# Register your OAuth App at: https://github.com/settings/developers
# Only the Client ID is needed (no secret required for device flow)
GITHUB_OAUTH_CLIENT_ID="Ov23li1tbzHTwdx5oUdy"
GITHUB_OAUTH_SCOPE="repo"  # Access private repos
GITHUB_TOKEN_FILE="$HOME/.onboard_github_token"
GITHUB_TOKEN_TYPE_FILE="$HOME/.onboard_github_token_type"  # "oauth" or "pat"

# --- USER CONFIG OVERRIDES ---
ONBOARD_RC="$HOME/.onboardrc"
if [[ -f "$ONBOARD_RC" ]]; then
    # shellcheck source=/dev/null
    source "$ONBOARD_RC"
fi

# --- COLORS & SYMBOLS ---
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_DIM="\033[2m"
C_UNDERLINE="\033[4m"
C_GREEN="\033[38;5;114m"
C_BLUE="\033[38;5;75m"
C_YELLOW="\033[38;5;221m"
C_RED="\033[38;5;203m"
C_CYAN="\033[38;5;117m"
C_GRAY="\033[38;5;245m"
C_WHITE="\033[38;5;255m"
C_MAGENTA="\033[38;5;176m"
C_ORANGE="\033[38;5;209m"

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
SYM_UPDATE="⟳"
SYM_GIT="⎇"
SYM_KEY="🔑"
SYM_GLOBE="🌐"
SYM_SPINNER_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")

# ─────────────────────────────────────────────────────────────────────────────
# UI HELPER FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────

_hr() {
    local width=62
    local line=""
    for ((i = 0; i < width; i++)); do line+="$SYM_LINE"; done
    echo -e "${C_GRAY}${line}${C_RESET}"
}

_banner() {
    echo ""
    _hr
    echo -e "${C_BOLD}${C_BLUE}  ${SYM_SCREEN}  SSH Onboarding Environment${C_RESET}  ${C_DIM}v${ONBOARD_VERSION}${C_RESET}"
    echo -e "${C_GRAY}     Screen + Python venv, auto-configured${C_RESET}"
    _hr
}

_step() {
    local symbol="$1" color="$2" message="$3"
    echo -e "  ${color}${symbol}${C_RESET}  ${C_WHITE}${message}${C_RESET}"
}

_step_ok()     { _step "$SYM_CHECK"  "$C_GREEN"   "$1"; }
_step_warn()   { _step "$SYM_WARN"   "$C_YELLOW"  "$1"; }
_step_fail()   { _step "$SYM_CROSS"  "$C_RED"     "$1"; }
_step_info()   { _step "$SYM_GEAR"   "$C_CYAN"    "$1"; }
_step_dim()    { _step "$SYM_DOTS"   "$C_GRAY"    "$1"; }
_step_lock()   { _step "$SYM_LOCK"   "$C_MAGENTA" "$1"; }
_step_update() { _step "$SYM_UPDATE" "$C_BLUE"    "$1"; }
_step_git()    { _step "$SYM_GIT"    "$C_MAGENTA" "$1"; }
_step_key()    { _step "$SYM_KEY"    "$C_ORANGE"  "$1"; }

# Animated spinner for long-running operations
_spinner_start() {
    local message="$1"
    _SPINNER_MSG="$message"
    _SPINNER_ACTIVE=1
    (
        local i=0
        while [[ -f "/tmp/.onboard_spinner_$$" ]]; do
            printf "\r  ${C_CYAN}${SYM_SPINNER_FRAMES[$((i % ${#SYM_SPINNER_FRAMES[@]}))]}${C_RESET}  ${C_WHITE}${_SPINNER_MSG}${C_RESET} "
            sleep 0.1
            ((i++))
        done
    ) &
    _SPINNER_PID=$!
    touch "/tmp/.onboard_spinner_$$"
}

_spinner_stop() {
    rm -f "/tmp/.onboard_spinner_$$" 2>/dev/null
    if [[ -n "${_SPINNER_PID:-}" ]]; then
        wait "$_SPINNER_PID" 2>/dev/null
        unset _SPINNER_PID
    fi
    printf "\r%-72s\r" " "
    _SPINNER_ACTIVE=0
}

_countdown() {
    local seconds="$1"
    for ((i = seconds; i > 0; i--)); do
        printf "\r  ${C_YELLOW}${SYM_ARROW}${C_RESET}  ${C_WHITE}Auto-attaching in ${C_BOLD}${C_YELLOW}%d${C_RESET}${C_WHITE}s ${C_DIM}(press any key to cancel)${C_RESET}  " "$i"
        if read -rsn1 -t 1; then
            printf "\r%-72s\r" " "
            return 0
        fi
    done
    printf "\r%-72s\r" " "
    return 1
}

_sysinfo() {
    local py_ver uptime_str disk_usage load_avg git_ver

    py_ver=$(python3 --version 2>/dev/null | awk '{print $2}' || echo "N/A")
    git_ver=$(git --version 2>/dev/null | awk '{print $3}' || echo "N/A")

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
    echo -e "  ${C_GRAY}│${C_RESET}  ${SYM_GIT}  Git:      ${C_CYAN}${git_ver}${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}  ⏱  Uptime:   ${C_WHITE}${uptime_str}${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}  💾 Disk:     ${C_WHITE}${disk_usage}${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}  📊 Load:     ${C_WHITE}${load_avg}${C_RESET}"
    echo -e "  ${C_GRAY}└───────────────────────────────────────────────────────┘${C_RESET}"
}

# ─────────────────────────────────────────────────────────────────────────────
# JSON PARSER (minimal, no jq dependency)
# ─────────────────────────────────────────────────────────────────────────────

# Extract a string value from JSON: _json_get '{"key":"val"}' "key" → val
_json_get() {
    local json="$1" key="$2"
    echo "$json" | grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | cut -d'"' -f4
}

# Extract a number value from JSON: _json_get_num '{"key":123}' "key" → 123
_json_get_num() {
    local json="$1" key="$2"
    echo "$json" | grep -o "\"${key}\"[[:space:]]*:[[:space:]]*[0-9]*" | head -1 | grep -o '[0-9]*$'
}

# ─────────────────────────────────────────────────────────────────────────────
# GITHUB OAUTH DEVICE FLOW
# ─────────────────────────────────────────────────────────────────────────────

_oauth_device_flow() {
    # Step 1: Request device and user verification codes
    _step_key "Starting GitHub OAuth Device Flow${SYM_DOTS}"
    echo ""

    if [[ "$GITHUB_OAUTH_CLIENT_ID" == "YOUR_CLIENT_ID_HERE" ]]; then
        _step_fail "OAuth Client ID not configured"
        echo ""
        echo -e "  ${C_GRAY}To set up OAuth:${C_RESET}"
        echo -e "  ${C_DIM}  1. Go to ${C_CYAN}${C_UNDERLINE}https://github.com/settings/developers${C_RESET}"
        echo -e "  ${C_DIM}  2. Create a new ${C_WHITE}OAuth App${C_RESET}"
        echo -e "  ${C_DIM}  3. Copy the ${C_WHITE}Client ID${C_RESET}"
        echo -e "  ${C_DIM}  4. Set it in ${C_CYAN}~/.onboardrc${C_RESET}${C_DIM}:${C_RESET}"
        echo -e "     ${C_DIM}GITHUB_OAUTH_CLIENT_ID=\"Ov23li...\"${C_RESET}"
        echo ""
        echo -e "  ${C_GRAY}Or use a Personal Access Token instead:${C_RESET}"
        echo -e "  ${C_DIM}  Run ${C_CYAN}$(basename "$SCRIPT_PATH") --setup-token${C_RESET}"
        return 1
    fi

    local device_response
    device_response=$(curl -sf -X POST \
        -H "Accept: application/json" \
        -d "client_id=${GITHUB_OAUTH_CLIENT_ID}&scope=${GITHUB_OAUTH_SCOPE}" \
        "https://github.com/login/device/code" 2>/dev/null)

    if [[ -z "$device_response" ]]; then
        _step_fail "Failed to contact GitHub — check your network"
        return 1
    fi

    local device_code user_code verification_uri expires_in interval
    device_code=$(_json_get "$device_response" "device_code")
    user_code=$(_json_get "$device_response" "user_code")
    verification_uri=$(_json_get "$device_response" "verification_uri")
    expires_in=$(_json_get_num "$device_response" "expires_in")
    interval=$(_json_get_num "$device_response" "interval")

    # Default interval if not provided
    interval=${interval:-5}

    if [[ -z "$device_code" || -z "$user_code" ]]; then
        _step_fail "Invalid response from GitHub"
        _step_dim "Response: ${device_response}"
        return 1
    fi

    # Step 2: Display the code to the user
    echo -e "  ${C_GRAY}┌──────────────────────────────────────────────────────┐${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}                                                      ${C_GRAY}│${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}   ${SYM_GLOBE} Open this URL on any device:                   ${C_GRAY}│${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}                                                      ${C_GRAY}│${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}   ${C_BOLD}${C_CYAN}${C_UNDERLINE}${verification_uri}${C_RESET}              ${C_GRAY}│${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}                                                      ${C_GRAY}│${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}   ${SYM_KEY} Enter this code:                               ${C_GRAY}│${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}                                                      ${C_GRAY}│${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}         ${C_BOLD}${C_GREEN}  ┌─────────────┐  ${C_RESET}                     ${C_GRAY}│${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}         ${C_BOLD}${C_GREEN}  │  ${C_WHITE}${C_BOLD}${user_code}  ${C_GREEN}│  ${C_RESET}                     ${C_GRAY}│${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}         ${C_BOLD}${C_GREEN}  └─────────────┘  ${C_RESET}                     ${C_GRAY}│${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}                                                      ${C_GRAY}│${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}   ${C_DIM}Code expires in $((expires_in / 60)) minutes${C_RESET}                          ${C_GRAY}│${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}                                                      ${C_GRAY}│${C_RESET}"
    echo -e "  ${C_GRAY}└──────────────────────────────────────────────────────┘${C_RESET}"
    echo ""

    # Step 3: Poll for authorization
    local elapsed=0
    local token_response access_token error

    while [[ "$elapsed" -lt "$expires_in" ]]; do
        local frame_idx=$(( (elapsed / interval) % ${#SYM_SPINNER_FRAMES[@]} ))
        printf "\r  ${C_CYAN}${SYM_SPINNER_FRAMES[$frame_idx]}${C_RESET}  ${C_WHITE}Waiting for authorization${C_DIM}${SYM_DOTS}${C_RESET} ${C_GRAY}(${elapsed}s / ${expires_in}s)${C_RESET}  "

        sleep "$interval"
        elapsed=$((elapsed + interval))

        token_response=$(curl -sf -X POST \
            -H "Accept: application/json" \
            -d "client_id=${GITHUB_OAUTH_CLIENT_ID}&device_code=${device_code}&grant_type=urn:ietf:params:oauth:grant-type:device_code" \
            "https://github.com/login/oauth/access_token" 2>/dev/null)

        access_token=$(_json_get "$token_response" "access_token")
        error=$(_json_get "$token_response" "error")

        if [[ -n "$access_token" ]]; then
            printf "\r%-72s\r" " "
            echo ""

            # Save the token
            echo "$access_token" > "$GITHUB_TOKEN_FILE"
            chmod 600 "$GITHUB_TOKEN_FILE"
            echo "oauth" > "$GITHUB_TOKEN_TYPE_FILE"
            chmod 600 "$GITHUB_TOKEN_TYPE_FILE"

            # Verify by getting user info
            local user_info username
            user_info=$(curl -sf -H "Authorization: token ${access_token}" \
                "https://api.github.com/user" 2>/dev/null)
            username=$(_json_get "$user_info" "login")

            _step_ok "Authenticated as ${C_BOLD}${C_CYAN}@${username:-unknown}${C_RESET}"
            _step_ok "OAuth token saved to ${C_CYAN}${GITHUB_TOKEN_FILE}${C_RESET} ${C_DIM}(chmod 600)${C_RESET}"

            return 0
        fi

        case "$error" in
            "authorization_pending")
                # Normal — user hasn't authorized yet, keep polling
                continue
                ;;
            "slow_down")
                # GitHub wants us to slow down
                interval=$((interval + 5))
                continue
                ;;
            "expired_token")
                printf "\r%-72s\r" " "
                _step_fail "Device code expired — please try again"
                return 1
                ;;
            "access_denied")
                printf "\r%-72s\r" " "
                _step_fail "Authorization denied by user"
                return 1
                ;;
            *)
                if [[ -n "$error" ]]; then
                    printf "\r%-72s\r" " "
                    _step_fail "Unexpected error: ${error}"
                    return 1
                fi
                ;;
        esac
    done

    printf "\r%-72s\r" " "
    _step_fail "Authorization timed out"
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# GITHUB TOKEN MANAGEMENT (unified: OAuth + PAT)
# ─────────────────────────────────────────────────────────────────────────────

_get_github_token() {
    # Priority: 1) Env var  2) Token file  3) git credential helper
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        echo "$GITHUB_TOKEN"
        return 0
    fi

    if [[ -f "$GITHUB_TOKEN_FILE" ]]; then
        local token
        token=$(cat "$GITHUB_TOKEN_FILE" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$token" ]]; then
            echo "$token"
            return 0
        fi
    fi

    # Legacy: check old PAT file location
    if [[ -f "$HOME/.github_token" ]]; then
        local token
        token=$(cat "$HOME/.github_token" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$token" ]]; then
            # Migrate to new location
            echo "$token" > "$GITHUB_TOKEN_FILE"
            chmod 600 "$GITHUB_TOKEN_FILE"
            echo "pat" > "$GITHUB_TOKEN_TYPE_FILE"
            chmod 600 "$GITHUB_TOKEN_TYPE_FILE"
            rm -f "$HOME/.github_token"
            echo "$token"
            return 0
        fi
    fi

    # Try git credential helper
    local cred_token
    cred_token=$(printf "protocol=https\nhost=github.com\n" | git credential fill 2>/dev/null | grep "password=" | cut -d= -f2)
    if [[ -n "$cred_token" ]]; then
        echo "$cred_token"
        return 0
    fi

    return 1
}

_get_token_type() {
    if [[ -f "$GITHUB_TOKEN_TYPE_FILE" ]]; then
        cat "$GITHUB_TOKEN_TYPE_FILE" 2>/dev/null | tr -d '[:space:]'
    elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
        echo "env"
    else
        echo "unknown"
    fi
}

_validate_token() {
    local token="$1"
    if [[ -z "$token" ]]; then return 1; fi

    local response http_code
    http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
        -H "Authorization: token ${token}" \
        "https://api.github.com/user" 2>/dev/null)

    [[ "$http_code" == "200" ]]
}

_revoke_oauth_token() {
    local token
    token=$(_get_github_token)
    local token_type
    token_type=$(_get_token_type)

    if [[ "$token_type" != "oauth" ]]; then
        _step_dim "Token is not OAuth — just removing local file"
        rm -f "$GITHUB_TOKEN_FILE" "$GITHUB_TOKEN_TYPE_FILE"
        return 0
    fi

    if [[ -n "$token" && "$GITHUB_OAUTH_CLIENT_ID" != "YOUR_CLIENT_ID_HERE" ]]; then
        _step_info "Revoking OAuth token on GitHub${SYM_DOTS}"
        # OAuth tokens can be revoked via the GitHub API
        local response
        response=$(curl -sf -X DELETE \
            -H "Authorization: token ${token}" \
            -H "Accept: application/json" \
            "https://api.github.com/applications/${GITHUB_OAUTH_CLIENT_ID}/token" \
            -d "{\"access_token\":\"${token}\"}" 2>/dev/null)
        _step_ok "OAuth token revoked"
    fi

    rm -f "$GITHUB_TOKEN_FILE" "$GITHUB_TOKEN_TYPE_FILE"
}

_setup_pat_token() {
    echo ""
    _step_info "Manual PAT Setup"
    echo ""
    echo -e "  ${C_GRAY}To generate a Personal Access Token:${C_RESET}"
    echo -e "  ${C_DIM}  1. Go to ${C_CYAN}${C_UNDERLINE}https://github.com/settings/tokens${C_RESET}"
    echo -e "  ${C_DIM}  2. Click ${C_WHITE}\"Generate new token (classic)\"${C_RESET}"
    echo -e "  ${C_DIM}  3. Select scope: ${C_WHITE}repo${C_RESET}"
    echo -e "  ${C_DIM}  4. Copy the token${C_RESET}"
    echo ""

    printf "  ${C_YELLOW}${SYM_ARROW}${C_RESET}  ${C_WHITE}Paste token (or press Enter to cancel): ${C_RESET}"
    read -rs user_token
    echo ""

    if [[ -n "$user_token" ]]; then
        # Validate before saving
        _step_info "Validating token${SYM_DOTS}"
        if _validate_token "$user_token"; then
            echo "$user_token" > "$GITHUB_TOKEN_FILE"
            chmod 600 "$GITHUB_TOKEN_FILE"
            echo "pat" > "$GITHUB_TOKEN_TYPE_FILE"
            chmod 600 "$GITHUB_TOKEN_TYPE_FILE"

            local user_info username
            user_info=$(curl -sf -H "Authorization: token ${user_token}" \
                "https://api.github.com/user" 2>/dev/null)
            username=$(_json_get "$user_info" "login")

            _step_ok "Authenticated as ${C_BOLD}${C_CYAN}@${username:-unknown}${C_RESET}"
            _step_ok "Token saved to ${C_CYAN}${GITHUB_TOKEN_FILE}${C_RESET}"
            return 0
        else
            _step_fail "Token validation failed — not saved"
            return 1
        fi
    else
        _step_dim "Cancelled"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# AUTHENTICATION MENU
# ─────────────────────────────────────────────────────────────────────────────

_auth_menu() {
    _banner
    echo ""

    # Check if already authenticated
    local existing_token
    existing_token=$(_get_github_token)

    if [[ -n "$existing_token" ]]; then
        local token_type username
        token_type=$(_get_token_type)

        if _validate_token "$existing_token"; then
            local user_info
            user_info=$(curl -sf -H "Authorization: token ${existing_token}" \
                "https://api.github.com/user" 2>/dev/null)
            username=$(_json_get "$user_info" "login")

            _step_ok "Currently authenticated as ${C_BOLD}${C_CYAN}@${username}${C_RESET} ${C_DIM}(${token_type})${C_RESET}"
            echo ""
            echo -e "  ${C_GRAY}Options:${C_RESET}"
            echo -e "    ${C_WHITE}1${C_RESET}  ${C_DIM}Re-authenticate (replace current token)${C_RESET}"
            echo -e "    ${C_WHITE}2${C_RESET}  ${C_DIM}Revoke and remove token${C_RESET}"
            echo -e "    ${C_WHITE}q${C_RESET}  ${C_DIM}Cancel${C_RESET}"
            echo ""
            printf "  ${C_YELLOW}${SYM_ARROW}${C_RESET}  ${C_WHITE}Choice: ${C_RESET}"
            read -rsn1 choice
            echo ""

            case "$choice" in
                1)
                    rm -f "$GITHUB_TOKEN_FILE" "$GITHUB_TOKEN_TYPE_FILE"
                    # Fall through to auth method selection below
                    ;;
                2)
                    _revoke_oauth_token
                    _step_ok "Token removed"
                    return 0
                    ;;
                *)
                    _step_dim "Cancelled"
                    return 0
                    ;;
            esac
        else
            _step_warn "Existing token is invalid or expired"
            rm -f "$GITHUB_TOKEN_FILE" "$GITHUB_TOKEN_TYPE_FILE"
            # Fall through to auth method selection
        fi
    fi

    # Auth method selection
    echo ""
    echo -e "  ${C_GRAY}┌──────────────────────────────────────────────────────┐${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}  ${SYM_KEY} ${C_BOLD}GitHub Authentication${C_RESET}                              ${C_GRAY}│${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}                                                      ${C_GRAY}│${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}  ${C_WHITE}1${C_RESET}  ${SYM_GLOBE} ${C_GREEN}OAuth Device Flow${C_RESET} ${C_DIM}(recommended)${C_RESET}            ${C_GRAY}│${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}     ${C_DIM}Opens a URL — approve from any device${C_RESET}         ${C_GRAY}│${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}                                                      ${C_GRAY}│${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}  ${C_WHITE}2${C_RESET}  ${SYM_LOCK} ${C_YELLOW}Personal Access Token${C_RESET} ${C_DIM}(manual)${C_RESET}             ${C_GRAY}│${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}     ${C_DIM}Paste a token from GitHub settings${C_RESET}           ${C_GRAY}│${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}                                                      ${C_GRAY}│${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}  ${C_WHITE}q${C_RESET}  ${C_DIM}Cancel${C_RESET}                                        ${C_GRAY}│${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}                                                      ${C_GRAY}│${C_RESET}"
    echo -e "  ${C_GRAY}└──────────────────────────────────────────────────────┘${C_RESET}"
    echo ""
    printf "  ${C_YELLOW}${SYM_ARROW}${C_RESET}  ${C_WHITE}Choice ${C_DIM}[1/2/q]${C_RESET}: "
    read -rsn1 auth_choice
    echo ""
    echo ""

    case "$auth_choice" in
        1)
            _oauth_device_flow
            ;;
        2)
            _setup_pat_token
            ;;
        *)
            _step_dim "Cancelled"
            return 1
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# SELF-UPDATE FROM GITHUB
# ─────────────────────────────────────────────────────────────────────────────

_should_check_update() {
    if [[ ! -f "$UPDATE_HASH_FILE" ]]; then
        return 0
    fi

    local last_check
    last_check=$(stat -c %Y "$UPDATE_HASH_FILE" 2>/dev/null || stat -f %m "$UPDATE_HASH_FILE" 2>/dev/null)
    local now
    now=$(date +%s)
    local elapsed=$(( now - last_check ))

    [[ "$elapsed" -ge "$UPDATE_CHECK_INTERVAL" ]]
}

_check_for_update() {
    if [[ -n "$STY" ]]; then return 1; fi
    if ! _should_check_update; then return 1; fi

    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        return 1
    fi

    local token
    token=$(_get_github_token)
    if [[ -z "$token" ]]; then
        return 1
    fi

    _step_update "Checking for updates${C_DIM}${SYM_DOTS}${C_RESET}"

    local remote_hash
    if command -v curl &>/dev/null; then
        remote_hash=$(curl -sf -H "Authorization: token ${token}" \
            -H "Accept: application/vnd.github.v3+json" \
            "$GITHUB_API_URL" 2>/dev/null | grep -m1 '"sha"' | cut -d'"' -f4)
    else
        remote_hash=$(wget -qO- --header="Authorization: token ${token}" \
            --header="Accept: application/vnd.github.v3+json" \
            "$GITHUB_API_URL" 2>/dev/null | grep -m1 '"sha"' | cut -d'"' -f4)
    fi

    if [[ -z "$remote_hash" ]]; then
        _step_dim "Could not reach GitHub ${C_DIM}(skipping)${C_RESET}"
        touch "$UPDATE_HASH_FILE" 2>/dev/null
        return 1
    fi

    local local_hash=""
    if [[ -f "$UPDATE_HASH_FILE" ]]; then
        local_hash=$(cat "$UPDATE_HASH_FILE" 2>/dev/null)
    fi

    if [[ "$remote_hash" == "$local_hash" ]]; then
        _step_ok "Already up to date ${C_DIM}(${remote_hash:0:8})${C_RESET}"
        touch "$UPDATE_HASH_FILE"
        return 1
    fi

    return 0
}

_perform_update() {
    local token
    token=$(_get_github_token)

    if [[ -z "$token" ]]; then
        _step_fail "No GitHub token available — cannot download update"
        return 1
    fi

    _step_update "Downloading latest version${C_DIM}${SYM_DOTS}${C_RESET}"

    local tmp_file
    tmp_file=$(mktemp /tmp/onboard_update.XXXXXX)

    if command -v curl &>/dev/null; then
        curl -sf \
            -H "Authorization: token ${token}" \
            -H "Accept: application/vnd.github.v3.raw" \
            "https://api.github.com/repos/${GITHUB_REPO}/contents/${GITHUB_SCRIPT_PATH}?ref=${GITHUB_BRANCH}" \
            -o "$tmp_file" 2>/dev/null
    else
        wget -qO "$tmp_file" \
            --header="Authorization: token ${token}" \
            --header="Accept: application/vnd.github.v3.raw" \
            "https://api.github.com/repos/${GITHUB_REPO}/contents/${GITHUB_SCRIPT_PATH}?ref=${GITHUB_BRANCH}" 2>/dev/null
    fi

    if [[ ! -s "$tmp_file" ]]; then
        _step_fail "Download failed — empty file"
        rm -f "$tmp_file"
        return 1
    fi

    if ! head -1 "$tmp_file" | grep -q "#!/bin/bash"; then
        _step_fail "Downloaded file doesn't look like a valid script"
        rm -f "$tmp_file"
        return 1
    fi

    local new_version
    new_version=$(grep '^ONBOARD_VERSION=' "$tmp_file" 2>/dev/null | head -1 | cut -d'"' -f2)
    new_version=${new_version:-"unknown"}

    echo ""
    _step_update "Update available: ${C_DIM}v${ONBOARD_VERSION}${C_RESET} → ${C_BOLD}${C_GREEN}v${new_version}${C_RESET}"

    if command -v diff &>/dev/null; then
        local changes
        changes=$(diff "$SCRIPT_PATH" "$tmp_file" 2>/dev/null | grep -c "^[<>]")
        _step_dim "${changes} lines changed"
    fi

    echo ""
    printf "  ${C_YELLOW}${SYM_ARROW}${C_RESET}  ${C_WHITE}Apply update? ${C_DIM}[Y/n]${C_RESET} "
    read -rsn1 -t 10 answer
    echo ""

    if [[ "$answer" == "n" || "$answer" == "N" ]]; then
        _step_dim "Update skipped"
        # Record hash to stop nagging
        local remote_hash
        remote_hash=$(curl -sf -H "Authorization: token ${token}" \
            -H "Accept: application/vnd.github.v3+json" \
            "$GITHUB_API_URL" 2>/dev/null | grep -m1 '"sha"' | cut -d'"' -f4)
        [[ -n "$remote_hash" ]] && echo "$remote_hash" > "$UPDATE_HASH_FILE"
        rm -f "$tmp_file"
        return 1
    fi

    # Backup
    local backup_file="${SCRIPT_PATH}.backup.$(date +%Y%m%d%H%M%S)"
    cp "$SCRIPT_PATH" "$backup_file"
    _step_dim "Backup: ${C_CYAN}${backup_file}${C_RESET}"

    # Apply
    mv "$tmp_file" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"

    # Record hash
    local remote_hash
    if command -v curl &>/dev/null; then
        remote_hash=$(curl -sf -H "Authorization: token ${token}" \
            -H "Accept: application/vnd.github.v3+json" \
            "$GITHUB_API_URL" 2>/dev/null | grep -m1 '"sha"' | cut -d'"' -f4)
    fi
    [[ -n "$remote_hash" ]] && echo "$remote_hash" > "$UPDATE_HASH_FILE"

    _step_ok "Updated to ${C_BOLD}v${new_version}${C_RESET}"
    _step_info "Changes take effect on next login or ${C_CYAN}source ${SCRIPT_PATH}${C_RESET}"

    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# LOCKING
# ─────────────────────────────────────────────────────────────────────────────

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

# ─────────────────────────────────────────────────────────────────────────────
# SSH AGENT FORWARDING PRESERVATION
# ─────────────────────────────────────────────────────────────────────────────

_preserve_ssh_agent() {
    if [[ -n "$SSH_AUTH_SOCK" && "$SSH_AUTH_SOCK" != "$SSH_SOCK_STABLE" ]]; then
        mkdir -p "$(dirname "$SSH_SOCK_STABLE")" 2>/dev/null
        ln -sf "$SSH_AUTH_SOCK" "$SSH_SOCK_STABLE" 2>/dev/null
        export SSH_AUTH_SOCK="$SSH_SOCK_STABLE"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# DEAD SCREEN SESSION CLEANUP
# ─────────────────────────────────────────────────────────────────────────────

_cleanup_dead_screens() {
    local dead_count
    dead_count=$(screen -ls 2>/dev/null | grep -c "Dead")
    if [[ "$dead_count" -gt 0 ]]; then
        _step_warn "Cleaning up ${dead_count} dead screen session(s)${SYM_DOTS}"
        screen -wipe >/dev/null 2>&1
        _step_ok "Dead sessions removed"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# ROOT CHECK
# ─────────────────────────────────────────────────────────────────────────────

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

# ─────────────────────────────────────────────────────────────────────────────
# PART 1: CROSS-PLATFORM INSTALLATION
# ─────────────────────────────────────────────────────────────────────────────

install_to_shell_rc() {
    local RC_FILE SHELL_NAME

    if [[ "$OSTYPE" == "darwin"* ]]; then
        RC_FILE="$HOME/.bash_profile"
        SHELL_NAME="macOS Bash"
    else
        RC_FILE="$HOME/.bashrc"
        SHELL_NAME="Linux Bash"
    fi

    if grep -q "# \[SSH ONBOARDING\]" "$RC_FILE" 2>/dev/null; then
        local installed_ver
        installed_ver=$(grep "# onboard-version:" "$RC_FILE" 2>/dev/null | awk '{print $NF}')
        if [[ "$installed_ver" == "$ONBOARD_VERSION" ]]; then
            _step_ok "Already installed ${C_DIM}v${ONBOARD_VERSION}${C_RESET} in ${C_CYAN}${RC_FILE}${C_RESET}"
            return 0
        else
            _step_warn "Upgrading ${C_DIM}v${installed_ver:-unknown}${C_RESET} → ${C_DIM}v${ONBOARD_VERSION}${C_RESET}"
            sed -i.bak '/# \[SSH ONBOARDING\]/,/^fi$/d' "$RC_FILE"
            rm -f "${RC_FILE}.bak"
        fi
    fi

    _step_info "Installing to ${C_CYAN}${RC_FILE}${C_RESET} ${C_DIM}(${SHELL_NAME})${C_RESET}"

    cat <<EOF >> "$RC_FILE"

# [SSH ONBOARDING] Auto-added by onboard.sh
# onboard-version: $ONBOARD_VERSION
# source-path: $SCRIPT_PATH
if [[ -f "$SCRIPT_PATH" ]]; then
    source "$SCRIPT_PATH"
fi
EOF
    _step_ok "Installation complete — activates on next login"
}

# ─────────────────────────────────────────────────────────────────────────────
# UNINSTALL
# ─────────────────────────────────────────────────────────────────────────────

uninstall_from_shell_rc() {
    local RC_FILE

    if [[ "$OSTYPE" == "darwin"* ]]; then
        RC_FILE="$HOME/.bash_profile"
    else
        RC_FILE="$HOME/.bashrc"
    fi

    if ! grep -q "# \[SSH ONBOARDING\]" "$RC_FILE" 2>/dev/null; then
        _step_warn "Not installed — nothing to remove"
        return 0
    fi

    _step_info "Removing onboard block from ${C_CYAN}${RC_FILE}${C_RESET}"
    sed -i.bak '/# \[SSH ONBOARDING\]/,/^fi$/d' "$RC_FILE"
    sed -i.bak '/^$/N;/^\n$/d' "$RC_FILE"
    rm -f "${RC_FILE}.bak"
    _step_ok "Uninstalled from ${C_CYAN}${RC_FILE}${C_RESET}"

    echo ""
    printf "  ${C_YELLOW}${SYM_ARROW}${C_RESET}  ${C_WHITE}Also remove token, venv, and config? ${C_DIM}[y/N]${C_RESET} "
    read -rsn1 answer
    echo ""

    if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
        # Revoke OAuth token if applicable
        if [[ -f "$GITHUB_TOKEN_FILE" ]]; then
            _revoke_oauth_token
        fi
        [[ -d "$VENV_DIR" ]]              && rm -rf "$VENV_DIR"             && _step_ok "Removed ${C_CYAN}${VENV_DIR}${C_RESET}"
        [[ -f "$UPDATE_HASH_FILE" ]]       && rm -f "$UPDATE_HASH_FILE"     && _step_ok "Removed ${C_CYAN}${UPDATE_HASH_FILE}${C_RESET}"
        [[ -f "$GITHUB_TOKEN_TYPE_FILE" ]] && rm -f "$GITHUB_TOKEN_TYPE_FILE"
        [[ -f "$ONBOARD_RC" ]]             && rm -f "$ONBOARD_RC"           && _step_ok "Removed ${C_CYAN}${ONBOARD_RC}${C_RESET}"
        _step_dim "Kept ${C_CYAN}${BASE_DIR}${C_RESET} (remove manually if desired)"
    else
        _step_dim "Kept all files intact"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# STATUS REPORT
# ─────────────────────────────────────────────────────────────────────────────

show_status() {
    _banner
    echo ""

    local RC_FILE
    if [[ "$OSTYPE" == "darwin"* ]]; then RC_FILE="$HOME/.bash_profile"; else RC_FILE="$HOME/.bashrc"; fi

    if grep -q "# \[SSH ONBOARDING\]" "$RC_FILE" 2>/dev/null; then
        local installed_ver
        installed_ver=$(grep "# onboard-version:" "$RC_FILE" 2>/dev/null | awk '{print $NF}')
        _step_ok "Installed in ${C_CYAN}${RC_FILE}${C_RESET} ${C_DIM}(v${installed_ver:-unknown})${C_RESET}"
    else
        _step_fail "Not installed in ${C_CYAN}${RC_FILE}${C_RESET}"
    fi

    # Dependencies
    if command -v screen &>/dev/null; then
        _step_ok "screen: ${C_CYAN}$(screen --version 2>/dev/null | head -1)${C_RESET}"
    else
        _step_fail "screen: ${C_RED}not found${C_RESET}"
    fi

    if command -v python3 &>/dev/null; then
        _step_ok "python3: ${C_CYAN}$(python3 --version 2>/dev/null)${C_RESET}"
    else
        _step_fail "python3: ${C_RED}not found${C_RESET}"
    fi

    if command -v git &>/dev/null; then
        _step_ok "git: ${C_CYAN}$(git --version 2>/dev/null)${C_RESET}"
    else
        _step_fail "git: ${C_RED}not found${C_RESET}"
    fi

    # Venv
    if [[ -d "$VENV_DIR" ]]; then
        _step_ok "Venv: ${C_CYAN}${VENV_DIR}${C_RESET}"
    else
        _step_dim "Venv: ${C_GRAY}not created yet${C_RESET}"
    fi

    # Authentication
    echo ""
    echo -e "  ${C_GRAY}Authentication:${C_RESET}"
    local token
    token=$(_get_github_token)
    if [[ -n "$token" ]]; then
        local token_type
        token_type=$(_get_token_type)
        if _validate_token "$token"; then
            local user_info username
            user_info=$(curl -sf -H "Authorization: token ${token}" \
                "https://api.github.com/user" 2>/dev/null)
            username=$(_json_get "$user_info" "login")
            _step_ok "GitHub: ${C_BOLD}${C_CYAN}@${username}${C_RESET} ${C_DIM}(${token_type})${C_RESET}"
        else
            _step_warn "GitHub: ${C_YELLOW}token invalid/expired${C_RESET} ${C_DIM}(${token_type})${C_RESET}"
        fi
    else
        _step_warn "GitHub: ${C_YELLOW}not authenticated${C_RESET}"
        _step_dim  "Run ${C_CYAN}$(basename "$SCRIPT_PATH") --login${C_RESET} to authenticate"
    fi

    # Last update check
    if [[ -f "$UPDATE_HASH_FILE" ]]; then
        local last_hash last_time
        last_hash=$(cat "$UPDATE_HASH_FILE" 2>/dev/null)
        if [[ "$OSTYPE" == "darwin"* ]]; then
            last_time=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$UPDATE_HASH_FILE" 2>/dev/null)
        else
            last_time=$(stat -c "%y" "$UPDATE_HASH_FILE" 2>/dev/null | cut -d. -f1)
        fi
        _step_ok "Last update: ${C_CYAN}${last_time}${C_RESET} ${C_DIM}(${last_hash:0:8})${C_RESET}"
    else
        _step_dim "Last update: ${C_GRAY}never${C_RESET}"
    fi

    # Screen sessions
    echo ""
    echo -e "  ${C_GRAY}Screen sessions:${C_RESET}"
    local sessions
    sessions=$(screen -ls 2>/dev/null | grep -E "\t" || echo "    (none)")
    echo -e "  ${C_DIM}${sessions}${C_RESET}"

    # Config
    echo ""
    echo -e "  ${C_GRAY}Configuration:${C_RESET}"
    echo -e "  ${C_DIM}  BASE_DIR         = ${C_CYAN}${BASE_DIR}${C_RESET}"
    echo -e "  ${C_DIM}  VENV_DIR         = ${C_CYAN}${VENV_DIR}${C_RESET}"
    echo -e "  ${C_DIM}  SCREEN_NAME      = ${C_CYAN}${SCREEN_NAME}${C_RESET}"
    echo -e "  ${C_DIM}  ATTACH_TIMEOUT   = ${C_CYAN}${ATTACH_TIMEOUT}s${C_RESET}"
    echo -e "  ${C_DIM}  GITHUB_REPO      = ${C_CYAN}${GITHUB_REPO}${C_RESET}"
    echo -e "  ${C_DIM}  UPDATE_INTERVAL  = ${C_CYAN}$((UPDATE_CHECK_INTERVAL / 3600))h${C_RESET}"
    if [[ "$GITHUB_OAUTH_CLIENT_ID" != "YOUR_CLIENT_ID_HERE" ]]; then
        echo -e "  ${C_DIM}  OAUTH_CLIENT_ID  = ${C_CYAN}${GITHUB_OAUTH_CLIENT_ID:0:12}...${C_RESET}"
    else
        echo -e "  ${C_DIM}  OAUTH_CLIENT_ID  = ${C_YELLOW}not configured${C_RESET}"
    fi
    if [[ -f "$ONBOARD_RC" ]]; then
        echo -e "  ${C_DIM}  Config file      = ${C_CYAN}${ONBOARD_RC}${C_RESET}"
    else
        echo -e "  ${C_DIM}  Config file      = ${C_GRAY}(using defaults)${C_RESET}"
    fi

    echo ""
    _sysinfo
    echo ""
    _hr
}

# ─────────────────────────────────────────────────────────────────────────────
# PART 2: DEPENDENCY CHECK
# ─────────────────────────────────────────────────────────────────────────────

ensure_dependencies() {
    if [[ -n "$STY" ]]; then return; fi

    local NEED_SCREEN=0 NEED_PYTHON=0 NEED_GIT=0

    command -v screen  &>/dev/null || NEED_SCREEN=1
    command -v python3 &>/dev/null || NEED_PYTHON=1
    command -v git     &>/dev/null || NEED_GIT=1

    if [[ "$NEED_SCREEN" -eq 0 && "$NEED_PYTHON" -eq 0 && "$NEED_GIT" -eq 0 ]]; then
        _step_ok "Dependencies satisfied ${C_DIM}(screen, python3, git)${C_RESET}"
        return 0
    fi

    _step_warn "Installing missing dependencies:"
    [[ "$NEED_SCREEN" -eq 1 ]] && echo -e "     ${C_GRAY}• screen${C_RESET}"
    [[ "$NEED_PYTHON" -eq 1 ]] && echo -e "     ${C_GRAY}• python3${C_RESET}"
    [[ "$NEED_GIT"    -eq 1 ]] && echo -e "     ${C_GRAY}• git${C_RESET}"

    local PACKAGES=()
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        [[ "$NEED_SCREEN" -eq 1 ]] && PACKAGES+=("screen")
        [[ "$NEED_PYTHON" -eq 1 ]] && PACKAGES+=("python3" "python3-venv")
        [[ "$NEED_GIT"    -eq 1 ]] && PACKAGES+=("git")

        _step_lock "Installing: ${C_DIM}${PACKAGES[*]}${C_RESET}"

        if command -v apt-get &>/dev/null; then
            sudo apt-get update -qq && sudo apt-get install -y -qq "${PACKAGES[@]}"
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y -q "${PACKAGES[@]}"
        elif command -v yum &>/dev/null; then
            sudo yum install -y -q "${PACKAGES[@]}"
        else
            _step_fail "Unknown package manager — install manually: ${PACKAGES[*]}"
            return 1
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        [[ "$NEED_SCREEN" -eq 1 ]] && PACKAGES+=("screen")
        [[ "$NEED_PYTHON" -eq 1 ]] && PACKAGES+=("python3")
        [[ "$NEED_GIT"    -eq 1 ]] && PACKAGES+=("git")

        if command -v brew &>/dev/null; then
            brew install "${PACKAGES[@]}"
        else
            _step_fail "Homebrew not found — install manually: ${PACKAGES[*]}"
            return 1
        fi
    fi

    local all_ok=1
    command -v screen  &>/dev/null || all_ok=0
    command -v python3 &>/dev/null || all_ok=0
    command -v git     &>/dev/null || all_ok=0

    if [[ "$all_ok" -eq 1 ]]; then
        _step_ok "Dependencies installed successfully"
    else
        _step_fail "Some dependencies could not be installed"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# PIP REQUIREMENTS AUTO-INSTALL
# ─────────────────────────────────────────────────────────────────────────────

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

# ─────────────────────────────────────────────────────────────────────────────
# PART 3: EXECUTION GUARDS & CLI
# ─────────────────────────────────────────────────────────────────────────────

# Guard: Non-interactive
[[ $- != *i* ]] && return 2>/dev/null

# Guard: Direct execution — CLI
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then

    case "${1:-}" in
        --help|-h)
            _banner
            echo ""
            echo -e "  ${C_BOLD}Usage:${C_RESET}"
            echo -e "    ${C_CYAN}./onboard.sh${C_RESET}                Install into shell profile"
            echo -e "    ${C_CYAN}./onboard.sh --login${C_RESET}        Authenticate with GitHub (OAuth or PAT)"
            echo -e "    ${C_CYAN}./onboard.sh --logout${C_RESET}       Revoke and remove GitHub token"
            echo -e "    ${C_CYAN}./onboard.sh --status${C_RESET}       Show configuration & health"
            echo -e "    ${C_CYAN}./onboard.sh --update${C_RESET}       Force check for script updates"
            echo -e "    ${C_CYAN}./onboard.sh --uninstall${C_RESET}    Remove from shell profile"
            echo -e "    ${C_CYAN}./onboard.sh --help${C_RESET}         Show this help"
            echo ""
            echo -e "  ${C_BOLD}Authentication:${C_RESET}"
            echo -e "    ${C_DIM}OAuth Device Flow (recommended):${C_RESET}"
            echo -e "      ${C_DIM}Requires a GitHub OAuth App Client ID.${C_RESET}"
            echo -e "      ${C_DIM}Set ${C_CYAN}GITHUB_OAUTH_CLIENT_ID${C_RESET}${C_DIM} in ${C_CYAN}~/.onboardrc${C_RESET}"
            echo ""
            echo -e "    ${C_DIM}Personal Access Token (manual):${C_RESET}"
            echo -e "      ${C_DIM}Generate at ${C_CYAN}https://github.com/settings/tokens${C_RESET}"
            echo ""
            echo -e "  ${C_BOLD}Config (${C_CYAN}~/.onboardrc${C_RESET}${C_BOLD}):${C_RESET}"
            echo -e "    ${C_DIM}BASE_DIR=\"\$HOME/projects\"${C_RESET}"
            echo -e "    ${C_DIM}SCREEN_NAME=\"dev\"${C_RESET}"
            echo -e "    ${C_DIM}ATTACH_TIMEOUT=5${C_RESET}"
            echo -e "    ${C_DIM}GITHUB_OAUTH_CLIENT_ID=\"Ov23li...\"${C_RESET}"
            echo -e "    ${C_DIM}UPDATE_CHECK_INTERVAL=3600${C_RESET}"
            echo ""
            _hr
            exit 0
            ;;
        --status|-s)
            show_status
            exit 0
            ;;
        --login|--auth)
            _auth_menu
            echo ""
            _hr
            exit 0
            ;;
        --logout)
            _banner
            echo ""
            if [[ -f "$GITHUB_TOKEN_FILE" ]]; then
                _revoke_oauth_token
                _step_ok "Logged out"
            else
                _step_dim "Not currently authenticated"
            fi
            echo ""
            _hr
            exit 0
            ;;
        --update|-u)
            _banner
            echo ""
            rm -f "$UPDATE_HASH_FILE"
            if _check_for_update; then
                _perform_update
            fi
            echo ""
            _hr
            exit 0
            ;;
        --setup-token)
            # Legacy compatibility — redirect to auth menu
            _auth_menu
            echo ""
            _hr
            exit 0
            ;;
        --uninstall)
            _banner
            echo ""
            uninstall_from_shell_rc
            echo ""
            _hr
            exit 0
            ;;
        --install|"")
            _banner
            echo ""
            _check_root || exit 1
            ensure_dependencies
            install_to_shell_rc
            echo ""

            # Prompt for authentication if not configured
            if ! _get_github_token &>/dev/null; then
                echo ""
                _step_warn "GitHub not authenticated — auto-updates disabled"
                printf "  ${C_YELLOW}${SYM_ARROW}${C_RESET}  ${C_WHITE}Authenticate now? ${C_DIM}[Y/n]${C_RESET} "
                read -rsn1 -t 5 answer
                echo ""
                if [[ "$answer" != "n" && "$answer" != "N" ]]; then
                    _auth_menu
                fi
            else
                local token username user_info
                token=$(_get_github_token)
                user_info=$(curl -sf -H "Authorization: token ${token}" \
                    "https://api.github.com/user" 2>/dev/null)
                username=$(_json_get "$user_info" "login")
                _step_ok "GitHub: ${C_BOLD}${C_CYAN}@${username:-authenticated}${C_RESET}"
            fi

            echo ""
            _hr
            _step_info "Run ${C_CYAN}source ~/.bashrc${C_RESET} or re-login to activate"
            _hr
            echo ""
            exit 0
            ;;
        *)
            _step_fail "Unknown option: ${C_CYAN}$1${C_RESET}"
            echo -e "  ${C_DIM}Run ${C_CYAN}./onboard.sh --help${C_RESET}${C_DIM} for usage${C_RESET}"
            exit 1
            ;;
    esac
fi

# ─────────────────────────────────────────────────────────────────────────────
# PART 4: SCREEN SESSION MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────

# Case A: Outside Screen
if [[ -z "$STY" ]]; then
    _check_root || return

    mkdir -p "$BASE_DIR"
    _preserve_ssh_agent
    _cleanup_dead_screens

    EXISTING_SESSION=$(screen -ls 2>/dev/null | grep -c "$SCREEN_NAME")

    _banner
    echo ""

    # Self-update check
    if _check_for_update; then
        _perform_update
        echo ""
    fi

    if [[ "$EXISTING_SESSION" -gt 0 ]]; then
        _step_info "Existing session found: ${C_CYAN}${SCREEN_NAME}${C_RESET}"
    else
        _step_info "Creating new session: ${C_CYAN}${SCREEN_NAME}${C_RESET}"
    fi

    echo ""

    if _countdown "$ATTACH_TIMEOUT"; then
        echo ""
        _step_warn "Cancelled — normal shell session"
        _step_dim  "To attach manually:  ${C_CYAN}screen -dRR ${SCREEN_NAME}${C_RESET}"
        _step_dim  "Authenticate:        ${C_CYAN}$(basename "$SCRIPT_PATH") --login${C_RESET}"
        _step_dim  "Session status:      ${C_CYAN}$(basename "$SCRIPT_PATH") --status${C_RESET}"
        _hr
        echo ""
    else
        _step_ok "Attaching${SYM_DOTS}"
        echo ""
        exec screen -dRR "$SCREEN_NAME"
    fi
fi

# Case B: Inside Screen
if [[ -n "$STY" && "$STY" == *"$SCREEN_NAME"* ]]; then

    _acquire_lock

    mkdir -p "$BASE_DIR"
    _preserve_ssh_agent

    # Venv creation
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

    # Activate
    if [[ -f "$VENV_DIR/bin/activate" ]]; then
        source "$VENV_DIR/bin/activate"
    fi

    _install_requirements

    _release_lock

    cd "$BASE_DIR" || true

    # Prompt
    export PS1="\[${C_RESET}\]\[${C_GREEN}\](venv)\[${C_RESET}\] \[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ "

    # Welcome (once)
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

        local token token_type
        token=$(_get_github_token)
        token_type=$(_get_token_type)
        if [[ -n "$token" ]]; then
            _step_ok "Auto-update:     ${C_CYAN}enabled${C_RESET} ${C_DIM}(${token_type})${C_RESET}"
        else
            _step_warn "Auto-update:     ${C_YELLOW}disabled${C_RESET} ${C_DIM}(run ${C_CYAN}$(basename "$SCRIPT_PATH") --login${C_DIM})${C_RESET}"
        fi

        _sysinfo

        echo ""
        _step_dim "Detach: ${C_WHITE}Ctrl-A D${C_RESET}${C_GRAY}  │  New window: ${C_WHITE}Ctrl-A C${C_RESET}${C_GRAY}  │  List: ${C_WHITE}Ctrl-A \"${C_RESET}"
        _hr
        echo ""
    fi
fi
