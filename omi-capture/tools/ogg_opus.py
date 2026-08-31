"""Wrap raw Opus frames in an Ogg container.

The pendant hands us bare Opus packets with no container, which nothing will
play. Rather than link a decoder, we mux them into Ogg Opus — after that any
player, ffmpeg, or transcription stack reads the file as ordinary audio, and
this stays pure Python with no native dependency to install on the host.

Nothing here re-encodes. The Opus payload is passed through untouched; only
framing is added. Whatever the pendant captured is exactly what comes out.

References: RFC 3533 (Ogg), RFC 7845 (Ogg Opus).
"""

from __future__ import annotations

import struct
from typing import Iterable

OPUS_RATE = 48000  # Ogg Opus granule positions are always in 48 kHz samples,
                   # whatever the encoder's input rate was.


def _crc_table() -> list[int]:
    """Ogg's CRC-32: polynomial 0x04c11db7, no reflection, no final xor.

    Not the same CRC-32 as zlib, which reflects both input and output. Using
    zlib here produces a file that looks right and that nothing will play.
    """
    table = []
    for i in range(256):
        r = i << 24
        for _ in range(8):
            if r & 0x80000000:
                r = ((r << 1) ^ 0x04C11DB7) & 0xFFFFFFFF
            else:
                r = (r << 1) & 0xFFFFFFFF
        table.append(r)
    return table


_CRC = _crc_table()


def _crc32(data: bytes) -> int:
    r = 0
    for b in data:
        r = ((r << 8) & 0xFFFFFFFF) ^ _CRC[((r >> 24) & 0xFF) ^ b]
    return r


def _lacing(length: int) -> list[int]:
    """Split a packet length into Ogg segment lacing values.

    A packet is described by 255-valued segments plus a final short one. A
    packet whose length is an exact multiple of 255 needs an explicit trailing
    zero, or the decoder keeps reading into the next packet.
    """
    segments = [255] * (length // 255)
    segments.append(length % 255)
    return segments


def _page(
    serial: int,
    sequence: int,
    granule: int,
    packets: list[bytes],
    *,
    first: bool = False,
    last: bool = False,
    continued: bool = False,
) -> bytes:
    segment_table: list[int] = []
    for p in packets:
        segment_table.extend(_lacing(len(p)))
    if len(segment_table) > 255:
        raise ValueError("too many segments for one page")

    header_type = (0x01 if continued else 0) | (0x02 if first else 0) | (0x04 if last else 0)

    header = bytearray()
    header += b"OggS"
    header += bytes([0])            # stream structure version
    header += bytes([header_type])
    header += struct.pack("<q", granule)
    header += struct.pack("<I", serial)
    header += struct.pack("<I", sequence)
    header += struct.pack("<I", 0)  # CRC placeholder, filled in below
    header += bytes([len(segment_table)])
    header += bytes(segment_table)

    body = b"".join(packets)
    page = bytes(header) + body
    crc = _crc32(page)
    # The checksum covers the whole page with its own field zeroed, so it can
    # only be written after the page is otherwise complete.
    return page[:22] + struct.pack("<I", crc) + page[26:]


def _opus_head(channels: int, input_rate: int, pre_skip: int = 0) -> bytes:
    return (
        b"OpusHead"
        + bytes([1])                        # version
        + bytes([channels])
        + struct.pack("<H", pre_skip)
        + struct.pack("<I", input_rate)     # informational only
        + struct.pack("<h", 0)              # output gain, Q7.8 dB
        + bytes([0])                        # channel mapping family
    )


def _opus_tags(vendor: bytes = b"omi-capture") -> bytes:
    return (
        b"OpusTags"
        + struct.pack("<I", len(vendor))
        + vendor
        + struct.pack("<I", 0)              # no user comments
    )


def write(
    path: str,
    frames: Iterable[bytes],
    *,
    channels: int = 1,
    input_rate: int = 16000,
    frame_ms: int = 20,
    serial: int = 0x4F4D4931,  # "OMI1"
) -> int:
    """Write frames to an Ogg Opus file. Returns the number of frames written."""
    samples_per_frame = OPUS_RATE * frame_ms // 1000

    with open(path, "wb") as fh:
        seq = 0
        # RFC 7845 requires the ID header alone on the first page, and the
        # comment header to begin on the second.
        fh.write(_page(serial, seq, 0, [_opus_head(channels, input_rate)], first=True))
        seq += 1
        fh.write(_page(serial, seq, 0, [_opus_tags()]))
        seq += 1

        batch: list[bytes] = []
        segments = 0
        granule = 0
        count = 0

        def flush(is_last: bool) -> None:
            nonlocal seq, batch, segments
            if not batch:
                return
            fh.write(_page(serial, seq, granule, batch, last=is_last))
            seq += 1
            batch = []
            segments = 0

        for frame in frames:
            need = len(_lacing(len(frame)))
            if segments + need > 255:
                flush(False)
            batch.append(frame)
            segments += need
            granule += samples_per_frame
            count += 1

        # The final page must be marked, and must carry the total granule
        # position, or players report the wrong duration and some refuse to seek.
        if batch:
            flush(True)
        else:
            fh.write(_page(serial, seq, granule, [b""], last=True))

    return count
