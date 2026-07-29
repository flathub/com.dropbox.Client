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
# the socket and the pid file do not.
#
# The lock is held by flock(1) itself, which forks, waits for the daemon, and
# releases the lock when the daemon exits. --close means the descriptor is
# closed in the child, so the daemon never sees it: it cannot clear the lock
# with an fd sweep during daemonization, and it cannot leak the lock into a
# helper process that outlives it. Nothing here depends on dropboxd's fd
# hygiene.
#
# See https://github.com/flathub/com.dropbox.Client/issues/395

set -eu

DAEMON=/app/extra/.dropbox-dist/dropboxd

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

# Reproduce the environment start_dropbox() sets up before spawning the
# daemon, since we are starting it ourselves.

# Resolve symlinks in the home path; Dropbox's filesystem support detection
# gets this wrong otherwise. See issue #392. Done before the lock path is
# derived, so the path in lslocks output matches the one the daemon reports.
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

STATE_DIR="${HOME}/.dropbox"
mkdir -p "$STATE_DIR"

cd "$HOME"

# Check if locking is available. Some FUSE mounts and NFS without lockd
# reject it. In that case, start the daemon unguarded.
probe=$(mktemp "${STATE_DIR}/.lockprobe.XXXXXX" 2>/dev/null) || probe=
if [ -z "$probe" ] || ! flock -n "$probe" true 2>/dev/null; then
    [ -z "$probe" ] || rm -f "$probe"
    echo "dropbox-launcher: file locking unavailable in ${STATE_DIR};" \
         "starting without the single-instance guard" >&2
    exec "$DAEMON"
fi
rm -f "$probe"

exec flock --nonblock --close --conflict-exit-code 0 \
     "${STATE_DIR}/flatpak-instance.lock" "$DAEMON"
