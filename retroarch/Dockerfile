ARG BUILD_FROM=ghcr.io/home-assistant/base:latest
FROM $BUILD_FROM

# RetroArch z Alpine; jadro SNES budujemy ze zrodel, bo Alpine ma je tylko w "testing"
RUN apk add --no-cache retroarch mesa-dri-gallium udev bash curl jq util-linux bluez mpv socat \
 && apk add --no-cache --virtual .build build-base linux-headers git \
 && git clone --depth 1 https://github.com/libretro/snes9x2010 /tmp/core \
 && make -C /tmp/core -f Makefile -j2 \
 && mkdir -p /usr/lib/libretro \
 && cp /tmp/core/snes9x2010_libretro.so /usr/lib/libretro/ \
 && rm -rf /tmp/core \
 && apk del .build
# Jadro PS1
RUN apk add --no-cache --virtual .build2 build-base linux-headers git zlib-dev \
    && git clone --depth 1 --recursive https://github.com/libretro/pcsx_rearmed /tmp/psx \
    && make -C /tmp/psx -f Makefile.libretro -j3 \
    && cp /tmp/psx/pcsx_rearmed_libretro.so /usr/lib/libretro/ \
    && rm -rf /tmp/psx \
    && apk del .build2
# Czcionka do napisow i licznika w bajkach
RUN apk add --no-cache ttf-dejavu fontconfig

COPY retroarch.cfg /etc/fh-retroarch.cfg
COPY run.sh /run.sh
RUN chmod a+x /run.sh
CMD ["/run.sh"]
