#!/usr/bin/env bash
# Deploy the brain + renderer sources to the Pi and build the renderer.
#   ./deploy.sh [--bootstrap] [user@host]
# Default host: the "wall" alias in ~/.ssh/config, which pins the address in
# one place because album-matrix.local resolves inconsistently on this
# network. Override with $ALBUM_PI_HOST or an argument.
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
HOST="${HOST:-${ALBUM_PI_HOST:-wall}}"

FILES=(brain renderer pi scripts)

echo ">>> syncing to $HOST"
rsync -a --delete --exclude '__pycache__' --exclude '.venv' "${FILES[@]}" "$HOST":album-art-matrix/

# The Pi OWNS its config. Deploys used to rsync the Mac's config.toml across
# and sed two keys back, which silently reverted every other Pi-side edit,
# including measured white-balance gains, the whole point of calibrating.
# The config is seeded once (with the two Pi-side flips applied and the
# outcome verified); after that the Pi's copy is never touched. Edit it on
# the Pi, or delete it there to re-seed from the Mac's copy.
if [ -f config.toml ]; then
  if ssh "$HOST" '[ -f ~/album-art-matrix/config.toml ]'; then
    echo ">>> config.toml already on the Pi — left alone (the Pi owns it)"
  else
    scp -q config.toml "$HOST":album-art-matrix/config.toml
    ssh "$HOST" 'cd ~/album-art-matrix && sed -i \
      -e "s|^type = \"preview\"|type = \"pi\"|" \
      -e "s|^endpoint = \"\"|endpoint = \"http://Jalens-MacBook-Pro.local:8787\"|" \
      config.toml \
      && grep -q "^type = \"pi\"" config.toml \
      && grep -q "^endpoint = \"http" config.toml' \
      || { echo ">>> config seed FAILED its check — fix ~/album-art-matrix/config.toml on the Pi"; exit 1; }
    echo ">>> config.toml seeded (sink=pi, endpoint=Mac reporter)"
  fi
fi

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

# The Apple Music account view on the Pi reads the same MusicKit credentials
# the Mac's widgets use. Copied, never moved; the helper on the Mac is untouched.
WS="$HOME/.config/widgetsuite"
if [ -f "$WS/musickit.p8" ] && [ -f "$WS/musickit.json" ] && [ -f "$WS/musickit-user-token.txt" ]; then
  ssh "$HOST" 'mkdir -p ~/.config/album-art-matrix/musickit && chmod 700 ~/.config/album-art-matrix/musickit'
  scp -q "$WS/musickit.p8" "$WS/musickit.json" "$WS/musickit-user-token.txt" \
      "$HOST":.config/album-art-matrix/musickit/
  echo ">>> MusicKit credentials on the Pi"
fi
