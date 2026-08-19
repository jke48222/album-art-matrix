#!/usr/bin/env bash
# One-time Pi 5 setup for album-art-matrix. Idempotent — safe to re-run.
# Run on the Pi (deploy.sh --bootstrap does it for you).
set -euo pipefail

echo ">>> apt dependencies (bitslip6 build deps + python)"
sudo apt-get update
sudo apt-get install -y build-essential gcc make git python3-venv python3-dev \
  libgles2-mesa-dev libgbm-dev libegl1-mesa-dev libavformat-dev libswscale-dev

echo ">>> zram swap (keeps the 1-2 GB boards comfortable; harmless on bigger ones)"
sudo apt-get install -y zram-tools
if ! grep -q '^PERCENT=' /etc/default/zramswap 2>/dev/null; then
  printf 'ALGO=zstd\nPERCENT=60\n' | sudo tee /etc/default/zramswap >/dev/null
  sudo systemctl restart zramswap 2>/dev/null || true
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

echo ">>> systemd unit (installed but not enabled — enable once it all works)"
sudo cp "$HOME/album-art-matrix/pi/album-art-matrix.service" /etc/systemd/system/
sudo systemctl daemon-reload

echo ""
echo "Bootstrap complete."
if [ "${NEED_REBOOT:-0}" = 1 ]; then
  echo ">>> cmdline.txt changed: REBOOT NOW (sudo reboot) before the first render."
fi
echo "Then: pi/run_renderer.sh in one shell, brain in another (see README)."
