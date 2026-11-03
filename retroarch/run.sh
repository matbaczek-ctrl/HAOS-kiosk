#!/usr/bin/with-contenv bashio
# Protokol stdin (hassio.addon_stdin):  play <gra> <osoba> <minuty>  |  quit
# Kiosk wraca zawsze: po koncu czasu, wyjsciu z gry, bledzie i zatrzymaniu aplikacji.
set -u
export QT_QPA_PLATFORM=offscreen
KIOSK=$(bashio::config 'kiosk_slug')
ROM_DIR=$(bashio::config 'rom_dir')
DATA=/config
CORE=/usr/lib/libretro/snes9x2010_libretro.so
GAME_PID=""
ENDED=""
MOVIE_DIR=/media/bajki

supervisor() { curl -sS -m 30 -X POST -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" "http://supervisor/addons/$1" >/dev/null; }

finish() {
    trap - EXIT INT TERM
    if [ -n "$GAME_PID" ] && kill -0 "$GAME_PID" 2>/dev/null; then
        for _ in $(seq 1 30); do kill -0 "$GAME_PID" 2>/dev/null || break; sleep 0.1; done
        kill -TERM "$GAME_PID" 2>/dev/null || true   # czyste wyjscie = zapis stanu gry
        for _ in $(seq 1 50); do kill -0 "$GAME_PID" 2>/dev/null || break; sleep 0.1; done
        kill -KILL "$GAME_PID" 2>/dev/null || true
    fi
    if [ "$ENDED" = time ]; then
        curl -sS -m 10 -X POST -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" -H "Content-Type: application/json" -d '{}' http://supervisor/core/api/services/script/fh_end_game >/dev/null || true
    fi
    bashio::log.info "Przywracam kiosk ${KIOSK}"
    supervisor "${KIOSK}/start" || bashio::log.error "Nie udalo sie uruchomic kiosku"
    exit 0
}
trap finish EXIT INT TERM

rom_for() {
    case "$1" in
        mario|smw) echo smw.sfc ;;
        bomberman) echo bomberman.sfc ;;
        zelda) echo zelda.sfc ;;
        pop) echo pop.sfc ;;
        kirby) echo kirby.sfc ;;
        mk3) echo mk3.sfc ;;
        thps2) echo thps2.iso ;;
        *) return 1 ;;
    esac
}

start_udev() {
    udevd --daemon || bashio::log.warning "udevd nie wystartowal"
    udevadm trigger; udevadm settle --timeout=10
    for dev in /dev/input/event*; do
        [ -c "$dev" ] || continue
        path=$(udevadm info --query=path --name="$dev" 2>/dev/null) && udevadm test "$path" >/dev/null 2>&1
    done
    udevadm settle --timeout=10
}

play() {
    local game=$1 person=$2 secs=$3 rom dir core=$CORE
    [ "$game" = thps2 ] && core=/usr/lib/libretro/pcsx_rearmed_libretro.so
    rom=$(rom_for "$game") || { bashio::log.error "Nieznana gra: $game"; return 1; }
    [[ "$person" =~ ^[a-z0-9_]{1,20}$ ]] || { bashio::log.error "Zla osoba"; return 1; }
    [[ "$secs" =~ ^[0-9]{1,4}$ ]] && [ "$secs" -ge 1 ] && [ "$secs" -le 3600 ] || { bashio::log.error "Zly czas"; return 1; }
    [ -r "$ROM_DIR/$rom" ] || { bashio::log.error "Brak pliku $ROM_DIR/$rom"; return 1; }

    bashio::log.info "Start: $game, $person, $secs s"
    supervisor "${KIOSK}/stop" || bashio::log.warning "Nie udalo sie zatrzymac kiosku"
    sleep 2                                # kiosk musi oddac ekran
    dir="$DATA/$person"; mkdir -p "$dir/saves" "$dir/states"
    { cat /etc/fh-retroarch.cfg
      echo "savefile_directory = \"$dir/saves\""
      echo "savestate_directory = \"$dir/states\""; } > /tmp/ra.cfg
    if [ "$game" = mario ] || [ "$game" = smw ]; then
        sed -i 's/^input_player2_joypad_index = .*/input_player2_joypad_index = "0"/' /tmp/ra.cfg
    fi
    retroarch --config /tmp/ra.cfg -f -L "$core" "$ROM_DIR/$rom" $(bashio::config.true 'debug' && echo --verbose) &
    GAME_PID=$!
    local end=$(( $(date +%s) + secs )) line left
    while kill -0 "$GAME_PID" 2>/dev/null; do
        [ "$(date +%s)" -ge "$end" ] && { bashio::log.info "Koniec czasu"; ENDED=time; return 0; }
        left=$(( end - $(date +%s) ))
        if [ $(( left % 3 )) -eq 0 ]; then
            printf 'SHOW_MSG Czas: %d:%02d' $(( left / 60 )) $(( left % 60 )) > /dev/udp/127.0.0.1/55355 2>/dev/null || true
        fi
        if read -r -t 1 line && [ "${line//\"/}" = quit ]; then ENDED=time; return 0; fi
    done
    bashio::log.info "Gra zakonczona"
}

mpv_cmd() { printf '{"command":[%s]}\n' "$1" | socat -t1 - UNIX-CONNECT:/tmp/mpv.sock >/dev/null 2>&1 || true; }

touch_devices() {
    awk 'BEGIN{RS="";FS="\n"} tolower($0) ~ /name=.*touch/ { if (match($0,/event[0-9]+/)) print "/dev/input/" substr($0,RSTART,RLENGTH) }' /proc/bus/input/devices
}

movie() {
    local person=$1 secs=$2 name=$3 file dir dev end now armed=0 quiet=0
    [[ "$person" =~ ^[a-z0-9_]{1,20}$ ]] || { bashio::log.error "Zla osoba"; return 1; }
    [[ "$secs" =~ ^[0-9]{1,4}$ ]] && [ "$secs" -ge 1 ] && [ "$secs" -le 3600 ] || { bashio::log.error "Zly czas"; return 1; }
    case "$name" in ""|*/*|*..*) bashio::log.error "Zla nazwa bajki"; return 1 ;; esac
    file="$MOVIE_DIR/$name"
    [ -r "$file" ] || { bashio::log.error "Brak pliku $file"; id; grep media /proc/mounts; ls -la /media "$MOVIE_DIR" 2>&1; locale 2>&1 | head -3; return 1; }

    bashio::log.info "Bajka: $name, $person, $secs s"
    supervisor "${KIOSK}/stop" || bashio::log.warning "Nie udalo sie zatrzymac kiosku"
    sleep 2
    dir="$DATA/$person/watch_later"; mkdir -p "$dir"
    mpv --no-config --fullscreen --vo=gpu --gpu-context=drm --hwdec=auto-copy-safe --ao=pulse,alsa \
        --no-input-terminal --no-terminal --save-position-on-quit --watch-later-dir="$dir" \
        --input-ipc-server=/tmp/mpv.sock --osd-font-size=34 --osd-align-x=right --osd-align-y=top --msg-level=all=warn --log-file=/tmp/mpv.log "$file" </dev/null &
    GAME_PID=$!
    grep -E "^(N: Name|H: Handlers)" /proc/bus/input/devices 2>&1 | head -30
    ls -l /dev/input/ 2>&1 | head -12
    bashio::log.info "Dotyk: [$(touch_devices | tr '\n' ' ')]"
    for dev in $(touch_devices); do
        ( while dd if="$dev" of=/dev/null bs=4096 count=1 2>/dev/null; do : > /tmp/tap; done ) &
    done
    end=$(( $(date +%s) + secs ))
    sleep 3; rm -f /tmp/tap
    while kill -0 "$GAME_PID" 2>/dev/null; do
        now=$(date +%s)
        if [ "$now" -ge "$end" ]; then
            bashio::log.info "Koniec czasu"; ENDED=time
            mpv_cmd '"quit-watch-later"'
            return 0
        fi
        if [ -e /tmp/tap ]; then
            rm -f /tmp/tap
            bashio::log.info "Dotkniecie ekranu (cisza $quiet)"
            if [ "$armed" -gt 0 ] && [ "$quiet" -ge 2 ] && [ $(( now - armed )) -le 8 ]; then
                mpv_cmd '"quit-watch-later"'
                return 0
            fi
            if [ "$armed" -eq 0 ] || [ $(( now - armed )) -gt 8 ]; then
                armed=$now
                quiet=0
                mpv_cmd '"show-text","Dotknij jeszcze raz, zeby wyjsc",4000'
            fi
            quiet=0
        else
            quiet=$(( quiet + 1 ))
        fi
        if [ "$armed" -eq 0 ] || [ $(( now - armed )) -gt 8 ]; then
            mpv_cmd "\"show-text\",\"Czas: $(( (end - now) / 60 )):$(printf %02d $(( (end - now) % 60 )))\",1500"
        fi
        if read -r -t 1 line && [ "${line//\"/}" = quit ]; then ENDED=time; mpv_cmd '"quit-watch-later"'; return 0; fi
    done
    tail -n 20 /tmp/mpv.log 2>/dev/null
    bashio::log.info "Bajka zakonczona"
}

pair_pad() {
    local old
    bashio::log.info "Parowanie: trzymaj Share + PS, az swiatlo zacznie podwojnie migac"
    old=$(bluetoothctl devices | grep -i 'wireless controller' | awk 'NR==1{print $2}' || true)
    if [ -n "$old" ]; then bluetoothctl remove "$old" || true; fi
    {
        printf 'power on\nagent NoInputNoOutput\ndefault-agent\npairable on\nscan on\n'
        mac=""
        for _ in $(seq 1 60); do
            mac=$(bluetoothctl devices | grep -i 'wireless controller' | awk 'NR==1{print $2}' || true)
            if [ -n "$mac" ]; then break; fi
            sleep 1
        done
        if [ -n "$mac" ]; then
            printf 'scan off\npair %s\n' "$mac"; sleep 10
            printf 'trust %s\n' "$mac"; sleep 2
            printf 'connect %s\n' "$mac"; sleep 10
            printf 'info %s\n' "$mac"; sleep 2
        fi
        printf 'quit\n'
    } | bluetoothctl
    ls -l /dev/input/ 2>&1
}

connect_pad() {
    local mac
    bluetoothctl show
    mac=$(bluetoothctl devices | grep -i 'wireless controller' | awk 'NR==1{print $2}')
    [ -n "$mac" ] || { bashio::log.error "Brak sparowanego pada"; return 1; }
    bluetoothctl trust "$mac" || true
    bluetoothctl info "$mac" | grep -E 'Trusted|Bonded' || true
    for _ in $(seq 1 20); do
        bluetoothctl --timeout 5 connect "$mac"
        bluetoothctl info "$mac" | grep -q 'Connected: yes' && { bashio::log.info "Pad polaczony"; break; }
        sleep 1
    done
    sleep 5
    bluetoothctl info "$mac"
    ls -l /dev/input/ 2>&1
}

bashio::config.true 'debug' && retroarch --features 2>&1 | grep -iE "kms|egl|udev|pulse"
start_udev
bashio::log.info "Czekam na polecenie play"
line=""
read -r -t 60 line
case "$line" in \"*) line=$(printf %s "$line" | jq -r . 2>/dev/null || printf %s "$line") ;; esac # stdin to JSON: polskie litery jako kody u0142
line=${line//\"/}                          # hassio.addon_stdin wysyla tekst w cudzyslowach
bashio::log.info "Polecenie: $line"
read -r cmd arg1 arg2 arg3 <<< "$line"
if [ "${cmd:-}" = play ]; then
    play "${arg1:-}" "${arg2:-}" "${arg3:-}"
elif [ "${cmd:-}" = movie ]; then
    movie "${arg1:-}" "${arg2:-}" "${arg3:-}"
elif [ "${cmd:-}" = pair ]; then
    pair_pad
elif [ "${cmd:-}" = connect ]; then
    connect_pad
else
    bashio::log.warning "Brak polecenia play, koncze"
fi
