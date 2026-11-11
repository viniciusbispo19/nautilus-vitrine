"""Gera `criar-vitrine.sh`: um único script bash que recria o projeto inteiro
(todos os arquivos) numa pasta e, se você quiser, já instala no Nautilus.

    python3 tools/build_bootstrap.py
"""

import os
import stat

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OUT = os.path.join(ROOT, "criar-vitrine.sh")
INCLUDE = [
    "nautilus-vitrine.py",
    "vitrine",
    "tools/smoke_test.py",
    "tools/build_bootstrap.py",
    "install.sh",
    "uninstall.sh",
    ".vscode",
    "README.md",
    "LICENSE",
    ".gitignore",
]
EXECUTABLE = {"install.sh", "uninstall.sh"}

HEADER = r'''#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  criar-vitrine.sh — cria o projeto "Vitrine para Nautilus" (Fedora / GNOME)
#
#  Uso:
#     bash criar-vitrine.sh                 # cria em ~/nautilus-vitrine
#     bash criar-vitrine.sh ~/Projetos/vit  # cria na pasta indicada
#     bash criar-vitrine.sh --instalar      # cria e já instala no Nautilus
#
#  Depois:  code ~/nautilus-vitrine   (abre no VS Code; Ctrl+Shift+B instala)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

TARGET="$HOME/nautilus-vitrine"
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --instalar|--install) INSTALL=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) TARGET="$arg" ;;
  esac
done

if [[ -e "$TARGET" && -n "$(ls -A "$TARGET" 2>/dev/null)" ]]; then
  read -r -p "A pasta $TARGET já existe e não está vazia. Sobrescrever os arquivos da Vitrine? [s/N] " ans
  [[ "${ans:-N}" =~ ^[SsYy]$ ]] || { echo "Cancelado."; exit 1; }
fi
mkdir -p "$TARGET"
cd "$TARGET"
echo "Criando arquivos em $TARGET …"

'''

FOOTER = r'''
chmod +x install.sh uninstall.sh
echo "Projeto criado em $TARGET"

if [[ "$INSTALL" == 1 ]]; then
  ./install.sh
else
  echo
  echo "Próximos passos:"
  echo "  cd \"$TARGET\" && ./install.sh        # instala e reinicia o Nautilus"
  echo "  code \"$TARGET\"                      # abre no VS Code (Ctrl+Shift+B = instalar em modo dev)"
fi
'''


def collect() -> list[str]:
    files = []
    for entry in INCLUDE:
        path = os.path.join(ROOT, entry)
        if os.path.isdir(path):
            for dirpath, dirnames, filenames in os.walk(path):
                dirnames[:] = sorted(d for d in dirnames if d != "__pycache__")
                for name in sorted(filenames):
                    if name.endswith((".pyc", ".tmp")):
                        continue
                    files.append(os.path.relpath(os.path.join(dirpath, name), ROOT))
        elif os.path.exists(path):
            files.append(entry)
    return files


def main() -> None:
    parts = [HEADER]
    for i, rel in enumerate(collect()):
        with open(os.path.join(ROOT, rel), encoding="utf-8") as fh:
            content = fh.read()
        delim = f"__VITRINE_ARQUIVO_{i}__"
        assert delim not in content
        if not content.endswith("\n"):
            content += "\n"
        d = os.path.dirname(rel)
        if d:
            parts.append(f'mkdir -p "{d}"\n')
        parts.append(f"cat > '{rel}' <<'{delim}'\n{content}{delim}\n")
    parts.append(FOOTER)
    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write("".join(parts))
    os.chmod(OUT, os.stat(OUT).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    print(f"gerado: {OUT}")


if __name__ == "__main__":
    main()
