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

supervisor() { curl -sS -m 30 -X POST -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" "http://supervisor/addons/$1" >/dev/null; }

finish() {
    trap - EXIT INT TERM
    if [ -n "$GAME_PID" ] && kill -0 "$GAME_PID" 2>/dev/null; then
        kill -TERM "$GAME_PID"            # czyste wyjscie = zapis stanu gry
        for _ in $(seq 1 50); do kill -0 "$GAME_PID" 2>/dev/null || break; sleep 0.1; done
        kill -KILL "$GAME_PID" 2>/dev/null
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
    local game=$1 person=$2 minutes=$3 rom dir
    rom=$(rom_for "$game") || { bashio::log.error "Nieznana gra: $game"; return 1; }
    [[ "$person" =~ ^[a-z0-9_]{1,20}$ ]] || { bashio::log.error "Zla osoba"; return 1; }
    [[ "$minutes" =~ ^[0-9]{1,2}$ ]] && [ "$minutes" -ge 1 ] && [ "$minutes" -le 60 ] || { bashio::log.error "Zly czas"; return 1; }
    [ -r "$ROM_DIR/$rom" ] || { bashio::log.error "Brak pliku $ROM_DIR/$rom"; return 1; }

    bashio::log.info "Start: $game, $person, $minutes min"
    supervisor "${KIOSK}/stop" || bashio::log.warning "Nie udalo sie zatrzymac kiosku"
    sleep 2                                # kiosk musi oddac ekran
    dir="$DATA/$person"; mkdir -p "$dir/saves" "$dir/states"
    { cat /etc/fh-retroarch.cfg
      echo "savefile_directory = \"$dir/saves\""
      echo "savestate_directory = \"$dir/states\""; } > /tmp/ra.cfg
    retroarch --config /tmp/ra.cfg -f -L "$CORE" "$ROM_DIR/$rom" $(bashio::config.true 'debug' && echo --verbose) &
    GAME_PID=$!
    local end=$(( $(date +%s) + minutes * 60 )) line
    while kill -0 "$GAME_PID" 2>/dev/null; do
        [ "$(date +%s)" -ge "$end" ] && { bashio::log.info "Koniec czasu"; return 0; }
        if read -r -t 1 line && [ "${line//\"/}" = quit ]; then return 0; fi
    done
    bashio::log.info "Gra zakonczona"
}

pair_pad() {
    local mac
    bashio::log.info "Parowanie: trzymaj Share + PS, az swiatlo zacznie podwojnie migac"
    bluetoothctl power on
    bluetoothctl --timeout 40 scan on
    bluetoothctl devices
    mac=$(bluetoothctl devices | grep -i 'wireless controller' | awk 'NR==1{print $2}')
    [ -n "$mac" ] || { bashio::log.error "Nie znaleziono pada"; return 1; }
    bashio::log.info "Znaleziono pada: $mac"
    bluetoothctl --agent NoInputNoOutput pair "$mac"
    bluetoothctl trust "$mac"
    bluetoothctl connect "$mac"
    sleep 3
    bluetoothctl info "$mac"
    ls -l /dev/input/ /dev/hidraw* 2>&1
}

bashio::config.true 'debug' && retroarch --features 2>&1 | grep -iE "kms|egl|udev|pulse"
start_udev
bashio::log.info "Czekam na polecenie play"
line=""
read -r -t 60 line
line=${line//\"/}                          # hassio.addon_stdin wysyla tekst w cudzyslowach
bashio::log.info "Polecenie: $line"
read -r cmd game person minutes _ <<< "$line"
if [ "${cmd:-}" = play ]; then
    play "${game:-}" "${person:-}" "${minutes:-}"
elif [ "${cmd:-}" = pair ]; then
    pair_pad
else
    bashio::log.warning "Brak polecenia play, koncze"
fi
