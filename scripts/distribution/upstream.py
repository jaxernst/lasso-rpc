"""Controlled RPC upstream for container acceptance checks (Python standard library)."""
import base64
import hashlib
import json
import socket
import select
import struct
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Upstream:
    def __init__(self, credential):
        self.credential = credential
        self.fail_first = False
        self.calls = {"/first": 0, "/second": 0}
        self.authenticated = 0
        self.events = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"
            def log_message(self, *_args):
                pass

            def do_POST(self):
                if self.headers.get("X-Release-Test") != owner.credential:
                    self.send_error(401)
                    return
                owner.authenticated += 1
                owner.calls[self.path] = owner.calls.get(self.path, 0) + 1
                request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                if owner.fail_first and self.path == "/first":
                    self.send_error(503)
                    return
                body = json.dumps(owner.reply(request)).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                if self.headers.get("Upgrade", "").lower() != "websocket":
                    self.send_error(404)
                    return
                if self.headers.get("X-Release-Test") != owner.credential:
                    self.send_error(401)
                    return
                key = self.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
                self.send_response(101)
                self.send_header("Upgrade", "websocket")
                self.send_header("Connection", "Upgrade")
                self.send_header("Sec-WebSocket-Accept", base64.b64encode(hashlib.sha1(key.encode()).digest()).decode())
                self.end_headers()
                self.connection.settimeout(5)
                subscribed = False
                for _ in range(180):
                    try:
                        if not select.select([self.connection], [], [], 1)[0]:
                            if subscribed:
                                event = {"jsonrpc": "2.0", "method": "eth_subscription", "params": {"subscription": "0xfeed", "result": owner.block()}}
                                self.frame(json.dumps(event).encode())
                            continue
                        header = self.rfile.read(2)
                        if len(header) != 2:
                            return
                        opcode, length = header[0] & 15, header[1] & 127
                        owner.events.append((self.path, "frame", opcode, length, bool(header[1] & 128)))
                        if length == 126:
                            length = struct.unpack("!H", self.rfile.read(2))[0]
                        elif length == 127:
                            length = struct.unpack("!Q", self.rfile.read(8))[0]
                        if length > 1_048_576:
                            return
                        mask = self.rfile.read(4) if header[1] & 128 else None
                        payload = self.rfile.read(length)
                        if mask:
                            payload = bytes(v ^ mask[i % 4] for i, v in enumerate(payload))
                        if opcode == 8:
                            return
                        if opcode == 9:
                            self.frame(payload, 10)
                        elif opcode == 1:
                            request = json.loads(payload)
                            owner.events.append((self.path, request.get("method")))
                            self.frame(json.dumps(owner.reply(request)).encode())
                            if request.get("method") == "eth_subscribe":
                                subscribed = True
                    except (socket.timeout, OSError):
                        if not subscribed:
                            return
                    if subscribed:
                        event = {"jsonrpc": "2.0", "method": "eth_subscription", "params": {"subscription": "0xfeed", "result": owner.block()}}
                        try:
                            self.frame(json.dumps(event).encode())
                        except OSError:
                            return

            def frame(self, payload, opcode=1):
                prefix = bytes([128 | opcode])
                prefix += bytes([len(payload)]) if len(payload) < 126 else bytes([126]) + struct.pack("!H", len(payload))
                self.connection.sendall(prefix + payload)

        self.server = ThreadingHTTPServer(("0.0.0.0", 0), Handler)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.port = self.server.server_port

    @staticmethod
    def block():
        return {"number": "0x1000", "hash": "0x" + "a" * 64, "parentHash": "0x" + "b" * 64, "timestamp": "0x65000000", "transactions": []}

    def reply(self, request):
        method = request.get("method")
        values = {"eth_chainId": "0x1", "eth_blockNumber": "0x1000", "net_version": "1", "eth_syncing": False, "eth_getLogs": [], "eth_getBalance": "0x0", "eth_call": "0x", "eth_subscribe": "0xfeed", "eth_unsubscribe": True}
        result = self.block() if method in ["eth_getBlockByNumber", "eth_getBlockByHash"] else values.get(method, "0x0")
        return {"jsonrpc": "2.0", "id": request.get("id"), "result": result}

    def close(self):
        self.server.shutdown()
        self.server.server_close()
