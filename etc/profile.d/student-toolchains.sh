# /etc/profile.d/student-toolchains.sh — PARED student toolchains
# Sourced by every login shell. Puts system-wide Go, Node.js, Neovim, and
# per-user tool dirs on PATH. Keep POSIX sh compatible.

# --- Go ---
if [ -d /usr/local/go/bin ]; then
    case ":${PATH}:" in
        *:/usr/local/go/bin:*) ;;
        *) PATH="/usr/local/go/bin:${PATH}" ;;
    esac
    # Per-user GOPATH so `go install` lands in the student's home.
    export GOPATH="${HOME}/go"
    case ":${PATH}:" in
        *:"${HOME}/go/bin":*) ;;
        *) PATH="${PATH}:${HOME}/go/bin" ;;
    esac
fi

# --- Node.js ---
if [ -d /opt/node/bin ]; then
    case ":${PATH}:" in
        *:/opt/node/bin:*) ;;
        *) PATH="/opt/node/bin:${PATH}" ;;
    esac
    # Keep global npm installs per-user (students have no sudo/write to /opt).
    export NPM_CONFIG_PREFIX="${HOME}/.npm-global"
    case ":${PATH}:" in
        *:"${HOME}/.npm-global/bin":*) ;;
        *) PATH="${PATH}:${HOME}/.npm-global/bin" ;;
    esac
fi

# --- pipx / local Python tools ---
case ":${PATH}:" in
    *:"${HOME}/.local/bin":*) ;;
    *) PATH="${PATH}:${HOME}/.local/bin" ;;
esac

# --- editor defaults ---
export EDITOR=nvim
export VISUAL=nvim

export PATH
