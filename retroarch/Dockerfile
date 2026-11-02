ARG BUILD_FROM=ghcr.io/home-assistant/base:latest
FROM $BUILD_FROM

# RetroArch z Alpine; jadro SNES budujemy ze zrodel, bo Alpine ma je tylko w "testing"
RUN apk add --no-cache retroarch mesa-dri-gallium udev bash curl jq util-linux bluez \
 && apk add --no-cache --virtual .build build-base linux-headers git \
 && git clone --depth 1 https://github.com/libretro/snes9x2010 /tmp/core \
 && make -C /tmp/core -f Makefile -j2 \
 && mkdir -p /usr/lib/libretro \
 && cp /tmp/core/snes9x2010_libretro.so /usr/lib/libretro/ \
 && rm -rf /tmp/core \
 && apk del .build

COPY retroarch.cfg /etc/fh-retroarch.cfg
COPY run.sh /run.sh
RUN chmod a+x /run.sh
CMD ["/run.sh"]
