#!/usr/bin/env bash
# One-time Pi 5 setup for album-art-matrix. Idempotent — safe to re-run.
# Run on the Pi (deploy.sh --bootstrap does it for you).
set -euo pipefail

echo ">>> apt dependencies (bitslip6 build deps + python)"
sudo apt-get update
sudo apt-get install -y build-essential gcc make git python3-venv python3-dev \
  libgles2-mesa-dev libgbm-dev libegl1-mesa-dev libavformat-dev libswscale-dev \
  libchromaprint-tools alsa-utils

echo ">>> zram swap (keeps the 1-2 GB boards comfortable; harmless on bigger ones)"
if grep -q '^/dev/zram' /proc/swaps; then
  echo "    OS already manages zram swap (Pi OS Trixie rpi-swap) — skipping zram-tools"
else
  sudo apt-get install -y zram-tools
  if ! grep -q '^PERCENT=' /etc/default/zramswap 2>/dev/null; then
    printf 'ALGO=zstd\nPERCENT=60\n' | sudo tee /etc/default/zramswap >/dev/null
    sudo systemctl restart zramswap 2>/dev/null || true
  fi
fi

echo ">>> bitslip6/rpi-gpu-hub75-matrix (built for the Adafruit Triple Bonnet)"
if [ ! -d "$HOME/rpi-gpu-hub75-matrix" ]; then
  git clone https://github.com/bitslip6/rpi-gpu-hub75-matrix "$HOME/rpi-gpu-hub75-matrix"
fi
cd "$HOME/rpi-gpu-hub75-matrix"
git pull --ff-only || true
make DEF="-D${HUB75_MAP:-ADA_3HAT}=1"   # ADA_3HAT = Adafruit bonnet; HZELLER = custom backplane
sudo make install
sudo ldconfig

echo ">>> isolating CPU 3 for the refresh thread (library requirement)"
CMDLINE=/boot/firmware/cmdline.txt
if ! grep -q 'isolcpus=3' "$CMDLINE"; then
  sudo sed -i 's/$/ isolcpus=3 nohz_full=3/' "$CMDLINE"
  NEED_REBOOT=1
fi

sudo usermod -aG gpio,video,render "$USER" || true

echo ">>> python env for the brain"
cd "$HOME/album-art-matrix"
python3 -m venv .venv
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q -r brain/requirements.txt

echo ">>> building the renderer"
cd "$HOME/album-art-matrix/renderer"
make

echo ">>> systemd units (installed but not enabled, enable once it all works)"
# The unit files are written for user "pi"; substitute the real user and home
# at install time so a Pi with a different login user still boots the wall.
for u in album-art-renderer.service album-art-matrix.service; do
  sed -e "s|^User=pi$|User=$USER|" -e "s|/home/pi|$HOME|g" \
    "$HOME/album-art-matrix/pi/$u" | sudo tee "/etc/systemd/system/$u" >/dev/null
done
sudo systemctl daemon-reload

echo ""
echo "Bootstrap complete."
if [ "${NEED_REBOOT:-0}" = 1 ]; then
  echo ">>> cmdline.txt changed: REBOOT NOW (sudo reboot) before the first render."
fi
echo "Then: pi/run_renderer.sh in one shell, brain in another (see README)."
echo "At the end of first light, both units survive a reboot with:"
echo "  sudo systemctl enable --now album-art-renderer album-art-matrix"
