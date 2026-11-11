"""Carregamento rápido de imagens para o preview.

No Fedora 45 o gdk-pixbuf usa o glycin, que abre um processo isolado (sandbox)
para cada imagem: ~50 ms só para ler as dimensões e ~70 ms+ para decodificar.
Aqui:

* JPEG/PNG/TIFF vão pelo decodificador interno do GTK (sem sandbox, ~3x mais rápido);
* dimensões e rotação EXIF são lidas direto do cabeçalho do arquivo, em Python;
* só fotos rotacionadas, gigantes ou de outros formatos (WebP, HEIC, AVIF…) usam o glycin;
* imagens já vistas ficam num cache; as vizinhas são pré-carregadas.
"""

from __future__ import annotations

import os
import struct
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor

import gi

gi.require_version("Gdk", "4.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gdk, GdkPixbuf, Gio  # noqa: E402

FAST_TYPES = ("image/jpeg", "image/png", "image/tiff")
FAST_MAX_PIXELS = 40_000_000  # acima disso, decodifica já reduzida (economiza memória)
SCALED_MAX_PX = 1600
HEADER_BYTES = 256 * 1024

EXECUTOR = ThreadPoolExecutor(max_workers=2, thread_name_prefix="vitrine-img")


class Probe:
    __slots__ = ("width", "height", "orientation")

    def __init__(self, width=0, height=0, orientation=1) -> None:
        self.width, self.height, self.orientation = width, height, orientation


def _probe_jpeg(data: bytes) -> Probe:
    p = Probe()
    if data[:2] != b"\xff\xd8":
        return p
    i = 2
    n = len(data)
    while i + 4 <= n:
        if data[i] != 0xFF:
            break
        marker = data[i + 1]
        if marker == 0xFF:  # bytes de preenchimento
            i += 1
            continue
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
            i += 2
            continue
        if marker in (0xD9, 0xDA):  # fim da imagem / início dos dados
            break
        seg_len = struct.unpack(">H", data[i + 2:i + 4])[0]
        seg = data[i + 4:i + 2 + seg_len]
        if marker == 0xE1 and seg[:6] == b"Exif\x00\x00":
            p.orientation = _exif_orientation(seg[6:]) or 1
        elif marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
            if len(seg) >= 5:
                p.height, p.width = struct.unpack(">HH", seg[1:5])
            break
        i += 2 + seg_len
    return p


def _exif_orientation(tiff: bytes) -> int:
    if len(tiff) < 8 or tiff[:2] not in (b"II", b"MM"):
        return 1
    e = "<" if tiff[:2] == b"II" else ">"
    ifd = struct.unpack(e + "I", tiff[4:8])[0]
    if ifd + 2 > len(tiff):
        return 1
    count = struct.unpack(e + "H", tiff[ifd:ifd + 2])[0]
    for k in range(count):
        off = ifd + 2 + 12 * k
        if off + 12 > len(tiff):
            break
        if struct.unpack(e + "H", tiff[off:off + 2])[0] == 0x0112:
            return struct.unpack(e + "H", tiff[off + 8:off + 10])[0]
    return 1


def probe(path: str, ct: str) -> Probe:
    """Dimensões e orientação lidas do cabeçalho, sem decodificar a imagem."""
    try:
        with open(path, "rb") as fh:
            data = fh.read(HEADER_BYTES if ct == "image/jpeg" else 64)
    except OSError:
        return Probe()
    if ct == "image/jpeg":
        return _probe_jpeg(data)
    if ct == "image/png" and data[:8] == b"\x89PNG\r\n\x1a\n" and data[12:16] == b"IHDR":
        w, h = struct.unpack(">II", data[16:24])
        return Probe(w, h, 1)
    return Probe()


def guess_type(path: str) -> str:
    ct, _uncertain = Gio.content_type_guess(path, None)
    return ct or ""


def cache_key(path: str):
    try:
        st = os.stat(path)
    except OSError:
        return None
    return (path, st.st_mtime_ns, st.st_size)


def load(path: str, ct: str):
    """Roda numa thread. Devolve (textura, largura_original, altura_original)."""
    pr = probe(path, ct)
    pixels = pr.width * pr.height
    if ct in FAST_TYPES and pr.orientation == 1 and pixels <= FAST_MAX_PIXELS:
        tex = Gdk.Texture.new_from_filename(path)
        return tex, (pr.width or tex.get_width()), (pr.height or tex.get_height())
    # Caminho lento (glycin): foto girada pelo EXIF, gigante ou formato não-nativo.
    pix = GdkPixbuf.Pixbuf.new_from_file_at_scale(path, SCALED_MAX_PX, SCALED_MAX_PX, True)
    pix = pix.apply_embedded_orientation() or pix
    w, h = pr.width, pr.height
    if pr.orientation in (5, 6, 7, 8):
        w, h = h, w
    return Gdk.Texture.new_for_pixbuf(pix), w, h


class TextureCache:
    """LRU em memória, limitado por quantidade e por total de pixels."""

    def __init__(self, max_items: int = 24, max_pixels: int = 160_000_000) -> None:
        self._items: OrderedDict = OrderedDict()
        self._max_items = max_items
        self._max_pixels = max_pixels
        self._pixels = 0

    def get(self, key):
        val = self._items.get(key)
        if val is not None:
            self._items.move_to_end(key)
        return val

    def __contains__(self, key) -> bool:
        return key in self._items

    def put(self, key, val) -> None:
        if key is None or key in self._items:
            return
        tex = val[0]
        self._items[key] = val
        self._pixels += tex.get_width() * tex.get_height()
        while self._items and (len(self._items) > self._max_items or self._pixels > self._max_pixels):
            _k, (old, _w, _h) = self._items.popitem(last=False)
            self._pixels -= old.get_width() * old.get_height()


CACHE = TextureCache()


def best_thumbnail(info: Gio.FileInfo) -> str | None:
    """A maior miniatura que o Nautilus/GNOME já gerou para o arquivo (carrega em ~1 ms)."""
    for suffix in ("-xxlarge", "-xlarge", "-large", "", "-normal"):
        path = info.get_attribute_byte_string(f"thumbnail::path{suffix}")
        if not path:
            continue
        valid_attr = f"thumbnail::is-valid{suffix}"
        if info.has_attribute(valid_attr) and not info.get_attribute_boolean(valid_attr):
            continue
        if os.path.exists(path):
            return path
    return None


THUMB_ATTRS = ",".join(
    f"thumbnail::{k}{s}"
    for s in ("", "-normal", "-large", "-xlarge", "-xxlarge")
    for k in ("path", "is-valid")
)
