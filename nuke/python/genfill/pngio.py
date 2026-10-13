"""Minimal, dependency-free PNG reader/writer.

Nuke's bundled Python has no PIL/numpy guarantee, so the few places where
GenFill has to look at pixels in Python (finding the selection bounds, the
offline mock backend) use this module. Heavy pixel work is always done by
Nuke nodes, never here.

Supports non-interlaced 8- and 16-bit greyscale, grey+alpha, RGB and RGBA
(16-bit is reduced to 8-bit on read). Palette images are expanded.
"""
from __future__ import annotations

import struct
import zlib

_SIG = b"\x89PNG\r\n\x1a\n"
_CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}


class PngError(ValueError):
    pass


class Image(object):
    """Simple 8-bit image: ``rows`` is a list of ``bytearray`` (top row first)."""

    __slots__ = ("width", "height", "channels", "rows")

    def __init__(self, width, height, channels, rows=None):
        self.width = int(width)
        self.height = int(height)
        self.channels = int(channels)
        if rows is None:
            rows = [bytearray(self.width * self.channels) for _ in range(self.height)]
        self.rows = rows

    def channel_value(self, x, y, c):
        return self.rows[y][x * self.channels + c]


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def _unfilter(data, width, height, bpp):
    stride = width * bpp
    rows = []
    prev = bytearray(stride)
    pos = 0
    for _ in range(height):
        ftype = data[pos]
        pos += 1
        line = bytearray(data[pos:pos + stride])
        pos += stride
        if ftype == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif ftype == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ftype == 3:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                upleft = prev[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + _paeth(left, prev[i], upleft)) & 0xFF
        elif ftype != 0:
            raise PngError("Unknown PNG filter type %d" % ftype)
        rows.append(line)
        prev = line
    return rows


def read(source):
    """Read a PNG from a path or bytes and return an 8-bit :class:`Image`."""
    if isinstance(source, (bytes, bytearray)):
        data = bytes(source)
    else:
        with open(source, "rb") as fh:
            data = fh.read()
    if data[:8] != _SIG:
        raise PngError("Not a PNG file")
    pos = 8
    idat = []
    palette = None
    width = height = depth = ctype = None
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        ctag = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if ctag == b"IHDR":
            width, height, depth, ctype, _comp, _filt, interlace = struct.unpack(">IIBBBBB", chunk)
            if interlace:
                raise PngError("Interlaced PNGs are not supported")
            if ctype not in _CHANNELS:
                raise PngError("Unsupported PNG colour type %r" % ctype)
            if depth not in (8, 16) and not (ctype == 3 and depth == 8):
                raise PngError("Unsupported PNG bit depth %r" % depth)
        elif ctag == b"PLTE":
            palette = chunk
        elif ctag == b"IDAT":
            idat.append(chunk)
        elif ctag == b"IEND":
            break
    if width is None:
        raise PngError("PNG has no IHDR chunk")
    raw = zlib.decompress(b"".join(idat))
    src_ch = _CHANNELS[ctype]
    bpp = src_ch * (depth // 8)
    rows = _unfilter(raw, width, height, bpp)
    if depth == 16:
        rows = [bytearray(r[0::2]) for r in rows]
    channels = src_ch
    if ctype == 3:
        if palette is None:
            raise PngError("Palette PNG without PLTE chunk")
        channels = 3
        out = []
        for r in rows:
            line = bytearray(width * 3)
            for x, idx in enumerate(r):
                line[x * 3:x * 3 + 3] = palette[idx * 3:idx * 3 + 3]
            out.append(line)
        rows = out
    return Image(width, height, channels, rows)


def _chunk(tag, payload):
    return (struct.pack(">I", len(payload)) + tag + payload
            + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))


def encode(image, level=6):
    """Encode an 8-bit :class:`Image` to PNG bytes."""
    ctype = {1: 0, 2: 4, 3: 2, 4: 6}[image.channels]
    raw = bytearray()
    for r in image.rows:
        raw.append(0)
        raw.extend(r)
    ihdr = struct.pack(">IIBBBBB", image.width, image.height, 8, ctype, 0, 0, 0)
    return (_SIG + _chunk(b"IHDR", ihdr) + _chunk(b"IDAT", zlib.compress(bytes(raw), level))
            + _chunk(b"IEND", b""))


def write(path, image):
    with open(path, "wb") as fh:
        fh.write(encode(image))


def size_of(data):
    """Return (width, height) from PNG bytes without decoding pixels."""
    if data[:8] != _SIG:
        raise PngError("Not a PNG file")
    return struct.unpack(">II", data[16:24])
