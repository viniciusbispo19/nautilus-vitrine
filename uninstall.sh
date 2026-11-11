#!/usr/bin/env bash
# Remove a Vitrine. Suas regras por pasta ficam em ~/.config/nautilus-vitrine
# (use --purge para apagá-las também).
set -euo pipefail
DEST="${XDG_DATA_HOME:-$HOME/.local/share}/nautilus-python/extensions"
rm -rf "$DEST/vitrine" "$DEST/nautilus-vitrine.py"
if [[ "${1:-}" == "--purge" ]]; then
  rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/nautilus-vitrine" "${XDG_CACHE_HOME:-$HOME/.cache}/nautilus-vitrine"
fi
nautilus -q 2>/dev/null || true
echo "Vitrine removida. Abra o Arquivos de novo para voltar ao Nautilus original."
