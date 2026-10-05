#!/usr/bin/env python3
"""Small static server with single-range support for playback fixtures."""

import argparse
import os
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from io import BytesIO


class RangeRequestHandler(SimpleHTTPRequestHandler):
    range_end = None

    def send_head(self):
        if self.path.split("?", 1)[0] == "/login-complete":
            body = b"""<!doctype html><html><head><title>Debug sign-in complete</title></head>
<body><main><h1>Signed in</h1><p>The debug authentication cookie was stored.</p></main></body></html>"""
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Set-Cookie", "debug_session=authenticated; Path=/; HttpOnly; SameSite=Lax")
            self.end_headers()
            return BytesIO(body)
        if self.path.split("?", 1)[0] == "/header-video.mp4":
            if self.headers.get("X-Debug-Video") != "allowed":
                self.send_error(403, "Missing debug video header")
                return None
            self.path = "/test.mp4"
        elif self.path.split("?", 1)[0] == "/header-audio.mp4":
            if self.headers.get("X-Debug-Audio") != "allowed":
                self.send_error(403, "Missing debug audio header")
                return None
            self.path = "/test.mp4"
        path = self.translate_path(self.path)
        supports_ranges = not self.path.startswith("/no-range.mp4")
        if not supports_ranges:
            path = os.path.join(os.path.dirname(path), "test.mp4")
        if os.path.isdir(path):
            return super().send_head()
        try:
            source = open(path, "rb")
        except OSError:
            self.send_error(404, "File not found")
            return None

        size = os.fstat(source.fileno()).st_size
        start, end = 0, size - 1
        requested = self.headers.get("Range") if supports_ranges else None
        if requested and requested.startswith("bytes=") and "," not in requested:
            first, last = requested[6:].split("-", 1)
            try:
                if first:
                    start = int(first)
                    end = int(last) if last else end
                elif last:
                    start = max(0, size - int(last))
            except ValueError:
                source.close()
                self.send_error(400, "Invalid byte range")
                return None
            if start >= size or end < start:
                source.close()
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.end_headers()
                return None
            end = min(end, size - 1)
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            source.seek(start)
            self.range_end = end
        else:
            self.send_response(200)
            self.range_end = None

        self.send_header("Content-Type", self.guess_type(path))
        if supports_ranges:
            self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Last-Modified", self.date_time_string(os.fstat(source.fileno()).st_mtime))
        self.end_headers()
        return source

    def copyfile(self, source, outputfile):
        if self.range_end is None:
            return super().copyfile(source, outputfile)
        remaining = self.range_end - source.tell() + 1
        while remaining > 0:
            chunk = source.read(min(64 * 1024, remaining))
            if not chunk:
                break
            outputfile.write(chunk)
            remaining -= len(chunk)


parser = argparse.ArgumentParser()
parser.add_argument("--bind", default="127.0.0.1")
parser.add_argument("--directory", default=os.getcwd())
parser.add_argument("port", type=int)
args = parser.parse_args()
handler = lambda *handler_args, **kwargs: RangeRequestHandler(
    *handler_args, directory=args.directory, **kwargs
)
ThreadingHTTPServer((args.bind, args.port), handler).serve_forever()
