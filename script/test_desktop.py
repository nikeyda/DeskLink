"""Loopback-only RFB fixture. Its desktop is a color chart held in memory."""

import argparse
import json
import socket
import struct
from pathlib import Path


def take(stream, count):
    data = stream.read(count)
    if len(data) != count:
        raise EOFError
    return data


def unpack(stream, fmt):
    return struct.unpack(fmt, take(stream, struct.calcsize(fmt)))


def record(stream, kind, **fields):
    if callable(stream):
        stream(kind, fields)
    else:
        print(json.dumps({"event": kind, **fields}), file=stream, flush=True)


def clipboard_fixture(connection, message):
    connection.sendall(struct.pack(">B3xI", 3, len(message)) + message)


def frame(width, height, pixel_format):
    bpp, _, big_endian, true_color, rmax, gmax, bmax, rs, gs, bs = struct.unpack(
        ">4B3H3B3x", pixel_format
    )
    if not true_color or bpp not in (8, 16, 32):
        raise ValueError("unsupported test pixel format")
    colors = [(31, 89, 165), (241, 183, 69), (52, 174, 146), (223, 102, 88)]
    palette = []
    for r, g, b in colors:
        pixel = (r * rmax // 255 << rs) | (g * gmax // 255 << gs) | (b * bmax // 255 << bs)
        palette.append(pixel.to_bytes(bpp // 8, "big" if big_endian else "little"))
    top = palette[0] * (width // 2) + palette[1] * (width - width // 2)
    bottom = palette[2] * (width // 2) + palette[3] * (width - width // 2)
    return top * (height // 2) + bottom * (height - height // 2)


def serve(connection, log, include_clipboard=True, two_monitors=False, bell_check=False, close_check=False,
          *, size=(320, 192), apple_server=False, capture_test_keys=False):
    width, height = size
    expected_chord = [(1, 0xffe3), (1, 0xffe9), (1, 0xffff), (0, 0xffff), (0, 0xffe9), (0, 0xffe3)]
    chord_progress = 0
    layout_sent = False
    supports_layout = False
    pixel_format = struct.pack(">4B3H3B3x", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
    label = (bytes(22) if apple_server else b"") + b"DeskLink Test Display"
    version = b"RFB 003.889\n" if apple_server else b"RFB 003.008\n"
    with connection, connection.makefile("rb") as stream:
        connection.settimeout(120)
        connection.sendall(version)
        if take(stream, 12) != version:
            raise ValueError("unexpected RFB version")
        connection.sendall(b"\x01\x01")
        if take(stream, 1) != b"\x01":
            raise ValueError("unexpected test security type")
        connection.sendall(bytes(4))
        take(stream, 1)
        connection.sendall(struct.pack(">HH", width, height) + pixel_format + struct.pack(">I", len(label)) + label)
        record(log, "serverInit", width=width, height=height)
        while True:
            kind = take(stream, 1)[0]
            if kind == 0:
                take(stream, 3)
                pixel_format = take(stream, 16)
            elif kind == 2:
                _, count = unpack(stream, ">BH")
                encodings = unpack(stream, ">" + "i" * count)
                supports_layout = -308 in encodings
            elif kind == 3:
                incremental, _, _, _, _ = unpack(stream, ">BHHHH")
                if not incremental:
                    layout = b""
                    if two_monitors and supports_layout and not layout_sent:
                        layout = struct.pack(">HHHHiB3x", 0, 0, width, height, -308, 2)
                        for display_id, left in [(73, 0), (19, width // 2)]:
                            layout += struct.pack(">I4HI", display_id, left, 0, width // 2, height, 0)
                        layout_sent = True
                        record(log, "monitorLayout", ids=[73, 19])
                    header = struct.pack(">BBH", 0, 0, 2 if layout else 1)
                    rectangle = struct.pack(">HHHHi", 0, 0, width, height, 0)
                    connection.sendall(header + layout + rectangle + frame(width, height, pixel_format))
                    record(log, "frame", width=width, height=height)
                    if include_clipboard:
                        clipboard_fixture(connection, b"DeskLink clipboard fixture")
            elif kind == 4:
                down, keysym = unpack(stream, ">B2xI")
                # Ordinary interoperability logs only retain the direction.
                record(log, "key", down=bool(down))
                if capture_test_keys:
                    record(log, "fixtureKey", down=bool(down), keysym=keysym)
                if keysym == 0xff63:
                    record(log, "fixtureInsert", down=bool(down))
                if (down, keysym) == expected_chord[chord_progress]:
                    chord_progress += 1
                    if chord_progress == len(expected_chord):
                        record(log, "fixtureDisconnectChord")
                        if include_clipboard:
                            clipboard_fixture(connection, b"DeskLink chord receipt")
                        chord_progress = 0
                else:
                    chord_progress = int((down, keysym) == expected_chord[0])
            elif kind == 5:
                buttons, x, y = unpack(stream, ">BHH")
                record(log, "pointer", buttons=buttons, x=x, y=y)
                if include_clipboard and (buttons, x, y) == (0, width - 1, height - 1):
                    clipboard_fixture(connection, b"DeskLink corner receipt")
            elif kind == 6:
                length, = unpack(stream, ">3xI")
                if length > 1024 * 1024:
                    raise ValueError("test clipboard length limit")
                data = take(stream, length)
                record(log, "clipboard", length=len(data), matchesTest=data == b"DeskLink clipboard fixture")
                if close_check and data == b"DeskLink end sharing":
                    record(log, "hostEndedSharing")
                    return
                if include_clipboard and data == b"DeskLink clipboard fixture":
                    clipboard_fixture(connection, b"DeskLink clipboard receipt")
                if bell_check and data in (b"after audible bell", b"after muted bell"):
                    connection.sendall(bytes([2]))
                    clipboard_fixture(connection, data)
                    record(log, "bell", muted=data == b"after muted bell")
            elif kind == 21 and apple_server:
                take(stream, 7)
            else:
                raise ValueError(f"unexpected client message {kind}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--ready", type=Path, required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--no-clipboard", action="store_true")
    parser.add_argument("--two-monitors", action="store_true")
    parser.add_argument("--bell-check", action="store_true")
    parser.add_argument("--close-check", action="store_true")
    args = parser.parse_args()
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server, args.log.open("w") as log:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", args.port))
        server.listen(2)
        args.ready.write_text(str(server.getsockname()[1]))
        while True:
            connection, _ = server.accept()
            try:
                serve(connection, log, include_clipboard=not args.no_clipboard,
                      two_monitors=args.two_monitors, bell_check=args.bell_check, close_check=args.close_check)
            except EOFError:
                record(log, "closed")
            except (OSError, ValueError) as error:
                record(log, "error", reason=str(error))


if __name__ == "__main__":
    main()
