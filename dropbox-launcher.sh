#!/bin/sh
# Single-instance launcher for the Dropbox Flatpak.
#
# is_dropbox_running() guards against a second daemon purely by connecting to
# ~/.dropbox/command_socket, which fails open whenever that socket is orphaned.
# A second daemon then runs against the same ~/.dropbox/instance1 database, and
# since the tray item's object path derives from the daemon's PID -- always the
# same low number, as every `flatpak run` gets a fresh PID namespace -- both
# register the identical /org/ayatana/NotificationItem/dropbox_client_<pid> and
# the panel shows two icons it cannot tell apart.
#
# A flock is namespace-independent, so it holds where the socket and the pid
# file do not. $XDG_RUNTIME_DIR is shared between instances of an app and
# tmpfs-backed, so locking always works there and the lock cannot outlive the
# session. flock(1) holds the descriptor itself and waits on the daemon;
# --close keeps it out of the daemon, which therefore cannot clear the lock
# with an fd sweep or leak it into a helper that outlives it.
#
# See https://github.com/flathub/com.dropbox.Client/issues/395

set -eu

DAEMON=/app/extra/.dropbox-dist/dropboxd

# Resolved before the cd below: we re-exec ourselves, and a relative $0 would
# not resolve from $HOME.
SELF=$(readlink -f "$0")

# Subcommands other than `start` are CLI operations (status, stop, exclude,
# ...) and must not take the lock. `start -i` is not honoured: we exec the
# daemon ourselves, so there is no interactive download step to run.
case "${1-start}" in
    start)
        ;;
    *)
        exec /app/bin/dropbox "$@"
        ;;
esac

# Reproduce the environment start_dropbox() sets up, since we start the daemon
# ourselves.

# Dropbox's filesystem support detection gets this wrong otherwise (issue #392).
HOME=$(readlink -f "$HOME")
export HOME
cd "$HOME"

# Fix indicator icon and menu on Unity (LP: #1559249) and Budgie
# (LP: #1683051) environments.
case ":${XDG_CURRENT_DESKTOP-}:" in
    *:Unity:*|*:Budgie:*)
        XDG_CURRENT_DESKTOP=Unity
        export XDG_CURRENT_DESKTOP
        ;;
esac

# Dropbox self-updates by unpacking a newer build into $HOME/.dropbox-dist and
# handing off to it. We ship updates through Flathub, so block that: the
# out-of-band build shares our ~/.dropbox instance database, and the handoff
# also costs us the lock -- flock waits on the process it started, so the
# bundled dropboxd exiting frees the lock seconds into startup while Dropbox
# keeps running. An unwritable directory is enough; dropboxd carries on with
# the build it was started from. dropbox-app.py did this until e82064c dropped
# it along with the rest of the script.
try_block_auto_updates() {
    updated=$HOME/.dropbox-dist

    # Already blocked by an earlier run.
    if [ -e "$updated" ] && [ ! -w "$updated" ]; then
        return 0
    fi
    if rm -rf "$updated" && mkdir -m 400 "$updated"; then
        return 0
    fi

    # A daemon on the wrong version beats no daemon, so carry on regardless.
    echo "dropbox-launcher: could not make ${HOME}/.dropbox-dist unwritable;" \
         "Dropbox may replace itself with an out-of-band build" >&2
}

# Safe only under the lock: a daemon answering the command socket from here is
# one that escaped it, since a daemon we started would still hold it and we
# would have exited at --conflict-exit-code 0. That escapee lives in the PID
# namespace of a `flatpak run` that has since gone away, so signals cannot
# reach it but the socket can. It also survives having $HOME/.dropbox-dist
# deleted -- its code is an already-open zip -- and goes on working against the
# shared instance database, so stopping it is the only way to get it off there.
#
# Only the current socket owner is reachable: a handoff chain can leave earlier
# orphans that nothing here can see. Those die with the session.
#
# `dropbox running` inverts the usual convention: 1 when a daemon answered.
stop_escaped_daemon() {
    if /app/bin/dropbox running >/dev/null 2>&1; then
        return 0
    fi

    echo "dropbox-launcher: stopping a daemon that escaped the instance lock" >&2
    /app/bin/dropbox stop >/dev/null 2>&1 || :

    # If it will not go, start anyway: refusing leaves the user with no daemon.
    i=0
    while [ "$i" -lt 50 ]; do
        if /app/bin/dropbox running >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.1
        i=$((i + 1))
    done
    echo "dropbox-launcher: it did not stop; starting anyway" >&2
}

# Flatpak always sets XDG_RUNTIME_DIR; a missing one must not stop Dropbox from
# starting. Without the lock there is no way to tell an escapee from a healthy
# daemon, so only the blocking half runs here.
if [ -z "${XDG_RUNTIME_DIR-}" ]; then
    echo "dropbox-launcher: XDG_RUNTIME_DIR is unset;" \
         "starting without the single-instance guard" >&2
    try_block_auto_updates
    exec "$DAEMON"
fi

# Re-enter under the lock so the cleanup below runs inside it; the final exec
# still leaves no extra process behind.
if [ -z "${DROPBOX_LAUNCHER_LOCKED-}" ]; then
    DROPBOX_LAUNCHER_LOCKED=1
    export DROPBOX_LAUNCHER_LOCKED
    exec flock --nonblock --close --conflict-exit-code 0 \
         "${XDG_RUNTIME_DIR}/dropbox-instance.lock" "$SELF" "$@"
fi

# Past here we hold the lock.
stop_escaped_daemon
try_block_auto_updates

# dropbox.pid names a PID from the namespace of whichever instance wrote it, so
# a file left by an earlier instance can name a live but unrelated process.
# dropboxd believes it and refuses to start -- "Another instance of Dropbox
# (<pid>) is running!" -- and the file persists across reboots, so a stale one
# blocks every launch until cleared. dropboxd writes a fresh one as it starts.
rm -f "${HOME}/.dropbox/dropbox.pid"

exec "$DAEMON"
