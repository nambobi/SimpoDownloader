#!/usr/bin/env bash
# SimpoDownloader installer for Linux / macOS (current user, no sudo).
#   curl -fsSL https://raw.githubusercontent.com/nambobi/SimpoDownloader/main/install.sh | bash
# Remove:  bash install.sh --uninstall
set -e
REPO_RAW="https://raw.githubusercontent.com/nambobi/SimpoDownloader/main"
DIR="$HOME/.local/share/simpodownloader"
BIN="$HOME/.local/bin"

if [ "$1" = "--uninstall" ]; then
  rm -rf "$DIR" "$BIN/simpodl"
  echo "SimpoDownloader removed."
  exit 0
fi

command -v python3 >/dev/null 2>&1 || { echo "Python 3 is required (Linux: sudo apt install python3)"; exit 1; }
mkdir -p "$DIR" "$BIN"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -n "$HERE" ] && [ -f "$HERE/simpodl.py" ]; then
  cp "$HERE/simpodl.py" "$DIR/simpodl.py"
else
  curl -fsSL "$REPO_RAW/simpodl.py" -o "$DIR/simpodl.py"
fi
chmod +x "$DIR/simpodl.py"
ln -sf "$DIR/simpodl.py" "$BIN/simpodl"

case ":$PATH:" in
  *":$BIN:"*) ;;
  *)
    RC="$HOME/.bashrc"; [ "$(basename "${SHELL:-bash}")" = "zsh" ] && RC="$HOME/.zshrc"
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$RC"
    echo "Added ~/.local/bin to PATH in $RC - open a new terminal."
    ;;
esac
echo "SimpoDownloader installed. Try:  simpodl help"
