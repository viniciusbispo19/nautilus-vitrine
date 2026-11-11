"""Vitrine para Nautilus: modo Colunas, pré-visualização lateral e visualização por pasta.

Este arquivo é o que o nautilus-python carrega. O código de verdade fica no
pacote `vitrine/` ao lado dele.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from vitrine.main import VitrineExtension  # noqa: E402,F401
