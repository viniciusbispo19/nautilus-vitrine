#!/usr/bin/env bash
# Instala a Vitrine para o seu usuário (não precisa de root, exceto para o nautilus-python).
#
#   ./install.sh          copia os arquivos
#   ./install.sh --dev    cria links simbólicos (edite no VS Code e só reinicie o Nautilus)
#   ./install.sh --no-restart
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${XDG_DATA_HOME:-$HOME/.local/share}/nautilus-python/extensions"
MODE="copy"
RESTART=1
for arg in "$@"; do
  case "$arg" in
    --dev) MODE="link" ;;
    --no-restart) RESTART=0 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
  esac
done

if ! rpm -q nautilus-python >/dev/null 2>&1; then
  echo "O pacote nautilus-python não está instalado; ele é necessário para carregar extensões em Python."
  read -r -p "Instalar agora com 'sudo dnf install nautilus-python'? [S/n] " ans
  if [[ "${ans:-S}" =~ ^[SsYy]$ ]]; then
    sudo dnf install -y nautilus-python
  else
    echo "Instale depois com: sudo dnf install nautilus-python"
    exit 1
  fi
fi

if rpm -q nautilus-vitrine >/dev/null 2>&1; then
  echo "Aviso: o pacote RPM nautilus-vitrine também está instalado."
  echo "Só uma cópia fica ativa (a primeira que o Nautilus carregar)."
  echo "Para testar esta cópia de desenvolvimento: sudo dnf remove nautilus-vitrine"
fi

mkdir -p "$DEST"
rm -rf "$DEST/vitrine" "$DEST/nautilus-vitrine.py"
if [[ "$MODE" == "link" ]]; then
  ln -s "$HERE/vitrine" "$DEST/vitrine"
  ln -s "$HERE/nautilus-vitrine.py" "$DEST/nautilus-vitrine.py"
  echo "Links de desenvolvimento criados em $DEST"
else
  cp -r "$HERE/vitrine" "$DEST/vitrine"
  cp "$HERE/nautilus-vitrine.py" "$DEST/nautilus-vitrine.py"
  find "$DEST/vitrine" -name '__pycache__' -prune -exec rm -rf {} +
  echo "Arquivos copiados para $DEST"
fi

if [[ "$RESTART" == 1 ]]; then
  echo "Reiniciando o Nautilus (janelas abertas do Arquivos serão fechadas)…"
  nautilus -q 2>/dev/null || true
  sleep 1
  (setsid nautilus >/dev/null 2>&1 &)
fi
echo "Pronto. Log: ${XDG_CACHE_HOME:-$HOME/.cache}/nautilus-vitrine/vitrine.log"
