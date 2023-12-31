#!/bin/sh

# the following is the LSB init header
#
### BEGIN INIT INFO
# Provides: libvirt-guests
# Required-Start: libvirtd
# Required-Stop: libvirtd
# Default-Start: 3 4 5
# Short-Description: suspend/resume libvirt guests on shutdown/boot
# Description: This is a script for suspending active libvirt guests
#              on shutdown and resuming them on next boot
#              See http://libvirt.org
### END INIT INFO

# the following is chkconfig init header
#
# libvirt-guests:   suspend/resume libvirt guests on shutdown/boot
#
# chkconfig: 345 98 02
# description:  This is a script for suspending active libvirt guests \
#               on shutdown and resuming them on next boot \
#               See http://libvirt.org
#

sysconfdir=/etc
localstatedir=/usr/lib/ssd/master
libvirtd=/usr/sbin/libvirtd

# Source function library.
. "$sysconfdir"/rc.d/init.d/functions

URIS=default
ON_BOOT=start
ON_SHUTDOWN=suspend
SHUTDOWN_TIMEOUT=0

test -f "$sysconfdir"/sysconfig/libvirt-guests && . "$sysconfdir"/sysconfig/libvirt-guests

#LISTFILE="$localstatedir"/lib/libvirt/libvirt-guests
LISTFILE="$localstatedir"/kvm_start
#VAR_SUBSYS_LIBVIRT_GUESTS="$localstatedir"/lock/subsys/libvirt-guests
VAR_SUBSYS_LIBVIRT_GUESTS="$localstatedir"/kvm_stop

RETVAL=0

retval() {
    "$@"
    if [ $? -ne 0 ]; then
        RETVAL=1
        return 1
    else
        return 0
    fi
}

run_virsh() {
    uri=$1
    shift

    if [ "x$uri" = xdefault ]; then
        conn=
    else
        conn="-c $uri"
    fi

    virsh $conn "$@" </dev/null
}

run_virsh_c() {
    ( export LC_ALL=C; run_virsh "$@" )
}

list_guests() {
    uri=$1

    list=$(run_virsh_c $uri list)
    if [ $? -ne 0 ]; then
        RETVAL=1
        return 1
    fi

    uuids=
    for id in $(echo "$list" | awk 'NR > 2 {print $1}'); do
        uuid=$(run_virsh_c $uri dominfo $id | awk '/^UUID:/{print $2}')
        if [ -z "$uuid" ]; then
            RETVAL=1
            return 1
        fi
        uuids="$uuids $uuid"
    done

    echo $uuids
}

guest_name() {
    uri=$1
    uuid=$2

    name=$(run_virsh_c $uri dominfo $uuid 2>/dev/null | \
           awk '/^Name:/{print $2}')
    [ -n "$name" ] || name=$uuid

    echo "$name"
}

guest_is_on() {
    uri=$1
    uuid=$2

    guest_running=false
    info=$(run_virsh_c $uri dominfo $uuid)
    if [ $? -ne 0 ]; then
        RETVAL=1
        return 1
    fi

    id=$(echo "$info" | awk '/^Id:/{print $2}')

    [ -n "$id" ] && [ "x$id" != x- ] && guest_running=true
    return 0
}

started() {
    touch "$VAR_SUBSYS_LIBVIRT_GUESTS"
}

start() {
    [ -f "$LISTFILE" ] || { started; return 0; }

    if [ "x$ON_BOOT" != xstart ]; then
        echo $"libvirt-guests is configured not to start any guests on boot"
        rm -f "$LISTFILE"
        started
        return 0
    fi

    while read uri list; do
        configured=false
        for confuri in $URIS; do
            if [ $confuri = $uri ]; then
                configured=true
                break
            fi
        done
        if ! $configured; then
            echo $"Ignoring guests on $uri URI"
            continue
        fi

        echo $"Resuming guests on $uri URI..."
        for guest in $list; do
            name=$(guest_name $uri $guest)
            echo -n $"Resuming guest $name: "
            if guest_is_on $uri $guest; then
                if $guest_running; then
                    echo $"already active"
                else
                    retval run_virsh $uri start "$name" >/dev/null && \
			virsh resume "$name"
                    echo $"done"
                fi
            fi
        done
    done <"$LISTFILE"

    rm -f "$LISTFILE"
    started
}

suspend_guest()
{
    uri=$1
    guest=$2

    name=$(guest_name $uri $guest)
    label=$"Suspending $name: "
    echo -n "$label"
    run_virsh $uri managedsave $guest >/dev/null &
    virsh_pid=$!
    while true; do
        sleep 1
        kill -0 $virsh_pid >&/dev/null || break
        progress=$(run_virsh_c $uri domjobinfo $guest 2>/dev/null | \
                   awk '/^Data processed:/{print $3, $4}')
        if [ -n "$progress" ]; then
            printf '\r%s%12s ' "$label" "$progress"
        else
            printf '\r%s%-12s ' "$label" "..."
        fi
    done
    retval wait $virsh_pid && printf '\r%s%-12s\n' "$label" $"done"
}

shutdown_guest()
{
    uri=$1
    guest=$2

    name=$(guest_name $uri $guest)
    label=$"Shutting down $name: "
    echo -n "$label"
    retval run_virsh $uri shutdown $guest >/dev/null || return
    timeout=$SHUTDOWN_TIMEOUT
    while [ $timeout -gt 0 ]; do
        sleep 1
        timeout=$[timeout - 1]
        guest_is_on $uri $guest || return
        $guest_running || break
        printf '\r%s%-12d ' "$label" $timeout
    done

    if guest_is_on $uri $guest; then
        if $guest_running; then
            printf '\r%s%-12s\n' "$label" $"failed to shutdown in time"
        else
            printf '\r%s%-12s\n' "$label" $"done"
        fi
    fi
}

stop() {
    # last stop was not followed by start
    [ -f "$LISTFILE" ] && return 0

    suspending=true
    if [ "x$ON_SHUTDOWN" = xshutdown ]; then
        suspending=false
        if [ $SHUTDOWN_TIMEOUT -le 0 ]; then
            echo $"Shutdown action requested but SHUTDOWN_TIMEOUT was not set"
            RETVAL=6
            return
        fi
    fi

    : >"$LISTFILE"
    for uri in $URIS; do
        echo -n $"Running guests on $uri URI: "

        if [ "x$uri" = xdefault ] && [ ! -x "$libvirtd" ]; then
            echo $"libvirtd not installed; skipping this URI."
            continue
        fi

        list=$(list_guests $uri)
        if [ $? -eq 0 ]; then
            empty=true
            for uuid in $list; do
                $empty || printf ", "
                echo -n $(guest_name $uri $uuid)
                empty=false
            done
            if $empty; then
                echo $"no running guests."
            else
                echo
                echo $uri $list >>"$LISTFILE"
            fi
        fi
    done

    while read uri list; do
        if $suspending; then
            echo $"Suspending guests on $uri URI..."
        else
            echo $"Shutting down guests on $uri URI..."
        fi

        for guest in $list; do
            if $suspending; then
                suspend_guest $uri $guest
            else
                shutdown_guest $uri $guest
            fi
        done
    done <"$LISTFILE"

    rm -f "$VAR_SUBSYS_LIBVIRT_GUESTS"
}

gueststatus() {
    for uri in $URIS; do
        echo "* $uri URI:"
        retval run_virsh $uri list || echo
    done
}

# rh_status
# Display current status: whether saved state exists, and whether start
# has been executed.  We cannot use status() from the functions library,
# since there is no external daemon process matching this init script.
rh_status() {
    if [ -f "$LISTFILE" ]; then
        echo $"stopped, with saved guests"
        RETVAL=3
    else
        if [ -f "$VAR_SUBSYS_LIBVIRT_GUESTS" ]; then
            echo $"started"
        else
            echo $"stopped, with no saved guests"
        fi
        RETVAL=0
    fi
}

# usage [val]
# Display usage string, then exit with VAL (defaults to 2).
usage() {
    echo $"Usage: $0 {start|stop|status|restart|condrestart|try-restart|reload|force-reload|gueststatus|shutdown}"
    exit ${1-2}
}

# See how we were called.
if test $# != 1; then
    usage
fi
case "$1" in
    --help)
        usage 0
        ;;
    start|stop|gueststatus)
        $1
        ;;
    restart)
        stop && start
        ;;
    condrestart|try-restart)
        [ -f "$VAR_SUBSYS_LIBVIRT_GUESTS" ] && stop && start
        ;;
    reload|force-reload)
        # Nothing to do; we reread configuration on each invocation
        ;;
    status)
        rh_status
        ;;
    shutdown)
        ON_SHUTDOWN=shutdown
        stop
        ;;
    *)
        usage
        ;;
esac
exit $RETVAL
