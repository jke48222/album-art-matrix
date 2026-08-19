#!/usr/bin/env bash
# Deploy the brain + renderer sources to the Pi and build the renderer.
#   ./deploy.sh [--bootstrap] [user@host]
# Default host: pi@album-matrix.local (set in Raspberry Pi Imager), or $ALBUM_PI_HOST.
# --bootstrap runs pi/bootstrap.sh remotely (first time only; needs sudo, hence -t).
set -euo pipefail
cd "$(dirname "$0")"

BOOTSTRAP=0
HOST=""
for a in "$@"; do
  case "$a" in
    --bootstrap) BOOTSTRAP=1 ;;
    *) HOST="$a" ;;
  esac
done
HOST="${HOST:-${ALBUM_PI_HOST:-pi@album-matrix.local}}"

FILES=(brain renderer pi scripts)
[ -f config.toml ] && FILES+=(config.toml)

echo ">>> syncing to $HOST"
rsync -a --delete --exclude '__pycache__' --exclude '.venv' "${FILES[@]}" "$HOST":album-art-matrix/

# Spotify tokens: authorize once on the Mac (browser needed), reuse on the headless Pi.
TOK="$HOME/.config/album-art-matrix/spotify_tokens.json"
if [ -f "$TOK" ]; then
  ssh "$HOST" 'mkdir -p ~/.config/album-art-matrix'
  scp -q "$TOK" "$HOST":.config/album-art-matrix/
  echo ">>> spotify tokens copied"
fi

if [ "$BOOTSTRAP" = 1 ]; then
  ssh -t "$HOST" 'bash ~/album-art-matrix/pi/bootstrap.sh'
else
  ssh "$HOST" 'cd ~/album-art-matrix/renderer && make' \
    || echo ">>> renderer build failed — run ./deploy.sh --bootstrap first"
fi
echo ">>> done"
