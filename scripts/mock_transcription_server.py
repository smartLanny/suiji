#!/usr/bin/env python3
"""Loopback-only ASR contract server for simulator testing; no speech recognition."""
import argparse
import json
import time
from email import policy
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, HTTPServer

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--port", type=int, default=8766)
parser.add_argument("--scenario", choices=["success", "empty", "unauthorized", "rate-limited"], default="success")
parser.add_argument("--duration", type=int, default=900, help="Exit automatically after this many seconds.")
args = parser.parse_args()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        size = int(self.headers.get("Content-Length", "0"))
        if self.path != "/v1/audio/transcriptions" or not 0 < size <= 26_000_000:
            self.send_error(400)
            return
        body = self.rfile.read(size)
        content_type = self.headers.get("Content-Type", "")
        message = BytesParser(policy=policy.default).parsebytes(
            b"Content-Type: " + content_type.encode() + b"\r\nMIME-Version: 1.0\r\n\r\n" + body
        )
        parts = {part.get_param("name", header="content-disposition"): part for part in message.iter_parts()}
        if not {"file", "model"} <= parts.keys() or not parts["file"].get_payload(decode=True):
            self.send_error(400)
            return
        status = {"success": 200, "empty": 200, "unauthorized": 401, "rate-limited": 429}[args.scenario]
        result = {"text": "【模拟接口测试】录音已上传，结果已回到时间线。这段文字来自本地测试服务，不是语音识别。" if args.scenario == "success" else ""}
        payload = json.dumps(result, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        print(f"POST /v1/audio/transcriptions -> {status}; audio bytes={len(parts['file'].get_payload(decode=True))}", flush=True)


print(f"Simulator mock ASR: http://127.0.0.1:{args.port}/v1, scenario={args.scenario}", flush=True)
server = HTTPServer(("127.0.0.1", args.port), Handler)
server.timeout = 1
deadline = time.monotonic() + args.duration
try:
    while time.monotonic() < deadline:
        server.handle_request()
finally:
    server.server_close()
