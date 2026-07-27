#!/bin/sh
# Single-instance launcher for the Dropbox Flatpak.
#
# Why this exists
# ---------------
# is_dropbox_running() decides whether a daemon is already running purely by
# connecting to ~/.dropbox/command_socket. That is the only guard against
# starting a second daemon, and it is not robust: if the socket is ever
# orphaned -- the owning daemon killed abruptly, or a second daemon rebinding
# and then unlinking it -- the check fails open.
#
# When it fails open the consequences are not subtle. A second daemon starts
# against the same ~/.dropbox/instance1 database, and because the tray item's
# object path is derived from the daemon's PID -- which is always the same low
# number, since every `flatpak run` gets a fresh PID namespace -- both
# instances register the identical
# /org/ayatana/NotificationItem/dropbox_client_<pid>. The panel then shows two
# tray icons that it cannot tell apart.
#
# A flock on the shared filesystem is namespace-independent, so it holds where
# the socket and the pid file do not. It is taken on fd 9, which survives the
# exec below, so the lock is held for the daemon's lifetime and released
# automatically however the daemon exits.
#
# See https://github.com/flathub/com.dropbox.Client/issues/395

set -eu

# Subcommands other than `start` are CLI operations (status, filestatus, stop,
# exclude, ...). Pass them straight through; they must not take the lock.
# `start -i` is deliberately not honoured: /app is read-only, so the daemon
# can never be downloaded at runtime, and the suggestion only misleads.
case "${1-start}" in
    start)
        ;;
    *)
        exec /app/bin/dropbox "$@"
        ;;
esac

STATE_DIR="${HOME}/.dropbox"
mkdir -p "$STATE_DIR"

exec 9>"${STATE_DIR}/flatpak-instance.lock"
if ! flock -n 9; then
    # Another sandbox instance already owns the daemon.
    exit 0
fi

# Reproduce the environment start_dropbox() sets up before spawning the
# daemon, since we are starting it ourselves.

# Resolve symlinks in the home path; Dropbox's filesystem support detection
# gets this wrong otherwise. See issue #392.
HOME=$(readlink -f "$HOME")
export HOME

# Fix indicator icon and menu on Unity (LP: #1559249) and Budgie
# (LP: #1683051) environments.
case ":${XDG_CURRENT_DESKTOP-}:" in
    *:Unity:*|*:Budgie:*)
        XDG_CURRENT_DESKTOP=Unity
        export XDG_CURRENT_DESKTOP
        ;;
esac

cd "$HOME"

exec /app/extra/.dropbox-dist/dropboxd
