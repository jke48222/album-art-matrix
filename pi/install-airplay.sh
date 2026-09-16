#!/bin/bash
# Build an isolated silent receiver. Root is needed only for packages and
# giving the local timing binary permission to bind UDP ports 319 and 320.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || dirname "$(dirname "$(realpath "$0")")")
if [ "${1:-}" = "--packages" ]; then
    sudo apt-get update
    sudo apt-get install --no-install-recommends build-essential git autoconf automake libtool pkg-config \
        libpopt-dev libconfig-dev libasound2-dev avahi-daemon libavahi-client-dev libssl-dev libsoxr-dev \
        libplist-dev libsodium-dev uuid-dev libgcrypt-dev xxd libplist-utils \
        libavutil-dev libavcodec-dev libavformat-dev libcap2-bin
fi
mkdir -p "$root/vendor" "$root/bin"
for project in nqptp shairport-sync; do
    source_dir="$root/vendor/$project"
    if [ ! -d "$source_dir/.git" ]; then
        git clone "https://github.com/mikebrady/$project" "$source_dir"
    fi
    if [ "$project" = nqptp ]; then
        revision=c925f27c1fd12e4033ac477e5a405969b0b0260b
    else
        revision=7bad231c18368dbd26f298577f6210e36e4b0797
    fi
    git -C "$source_dir" checkout --detach "$revision"
    git -C "$source_dir" submodule update --init --recursive
    (
        cd "$source_dir"
        autoreconf -fi
        if [ "$project" = nqptp ]; then
            ./configure --prefix="$root/vendor/airplay-runtime"
        else
            ./configure --prefix="$root/vendor/airplay-runtime" --with-alsa --with-stdout \
                --with-soxr --with-avahi --with-ssl=openssl --with-airplay-2 --with-metadata-pipe
        fi
        make -j 2
    )
    install -m 755 "$source_dir/$project" "$root/bin/$project"
    echo "[airplay] built $project $revision"
done
sudo setcap cap_net_bind_service=+ep "$root/bin/nqptp"
"$root/bin/shairport-sync" -V
/usr/sbin/getcap "$root/bin/nqptp"
echo '[airplay] ready; the brain starts both programs only while its feature is enabled'
