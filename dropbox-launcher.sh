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
# A flock is namespace-independent, so it holds where the socket and the pid
# file do not. It lives in $XDG_RUNTIME_DIR, which Flatpak shares between all
# instances of an app and backs with a tmpfs: locking is always available
# there, and the lock cannot outlive the session.
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
# `start -i` is not honoured: we exec the daemon ourselves, so there is no
# interactive download step to run.
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

# Dropbox self-updates into $HOME/.dropbox-dist; when that copy is newer, the
# bundled dropboxd hands off to it and exits. flock waits on the process it
# started, so that handoff releases the lock seconds into startup while Dropbox
# keeps running, and the next launch is free to start a duplicate daemon against
# the same instance database -- the tray icons of issue #395. Exec the newer
# copy directly instead, leaving no handoff to lose the lock to.
BUNDLED=/app/extra/.dropbox-dist
UPDATED=$HOME/.dropbox-dist
if [ -x "$UPDATED/dropboxd" ] && [ -r "$UPDATED/VERSION" ] && [ -r "$BUNDLED/VERSION" ]; then
    bundled=$(cat "$BUNDLED/VERSION")
    updated=$(cat "$UPDATED/VERSION")
    newest=$(printf '%s\n%s\n' "$bundled" "$updated" | sort -V | tail -n 1)
    if [ "$updated" != "$bundled" ] && [ "$newest" = "$updated" ]; then
        DAEMON=$UPDATED/dropboxd
    fi
fi

# Flatpak always sets XDG_RUNTIME_DIR, so this is purely defensive; but a
# missing one must not stop Dropbox from starting.
if [ -z "${XDG_RUNTIME_DIR-}" ]; then
    echo "dropbox-launcher: XDG_RUNTIME_DIR is unset;" \
         "starting without the single-instance guard" >&2
    exec "$DAEMON"
fi

# dropbox.pid holds a PID from the namespace of whichever instance wrote it, and
# every `flatpak run` gets a fresh one, so a file left by an earlier instance can
# name a live but unrelated process. dropboxd believes it and refuses to start --
# "Another instance of Dropbox (<pid>) is running!" -- so clear it; dropboxd
# writes a fresh one as it comes up. sh execs the daemon, so this costs no
# process and --close still keeps the lock descriptor out of dropboxd.
# shellcheck disable=SC2016  # $1/$2 are the inner sh's parameters, passed below.
exec flock --nonblock --close --conflict-exit-code 0 \
     "${XDG_RUNTIME_DIR}/dropbox-instance.lock" \
     /bin/sh -c 'rm -f "$1"; exec "$2"' sh "${HOME}/.dropbox/dropbox.pid" "$DAEMON"
