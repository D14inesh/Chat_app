"""Static server for the frontend — standard library only, no install needed.

  python serve.py           ->  http://localhost:5173  (+ https://<lan-ip>:5443 when certs/ exist)

The frontend is plain HTML/CSS/JS in public/, so any static host works in
production (nginx, IIS, Netlify, ...). Set the backend URL in public/config.js.
"""
import functools
import os
import ssl
import threading
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
PUBLIC_DIR = HERE / "public"
CERT_DIR = HERE / "certs"
HTTP_PORT = int(os.environ.get("FRONTEND_PORT", "5173"))
HTTPS_PORT = int(os.environ.get("FRONTEND_HTTPS_PORT", "5443"))


class Handler(SimpleHTTPRequestHandler):
    extensions_map = {**SimpleHTTPRequestHandler.extensions_map, ".js": "text/javascript", ".json": "application/json"}

    def end_headers(self):
        # CSS/JS change often during development — always revalidate instead
        # of serving a stale cached copy.
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()

    def do_GET(self):
        # An unknown extension-less path lands on the app shell rather than a
        # bare 404 page.
        if not Path(self.translate_path(self.path)).exists() and "." not in Path(self.path.split("?")[0]).name:
            self.path = "/index.html"
        super().do_GET()


def serve(server: ThreadingHTTPServer):
    server.serve_forever()


def main():
    handler = functools.partial(Handler, directory=str(PUBLIC_DIR))
    servers = [ThreadingHTTPServer(("0.0.0.0", HTTP_PORT), handler)]
    print(f"\n  Frontend at http://localhost:{HTTP_PORT}")

    cert, key = CERT_DIR / "cert.pem", CERT_DIR / "key.pem"
    if cert.exists() and key.exists():
        https = ThreadingHTTPServer(("0.0.0.0", HTTPS_PORT), handler)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(cert, key)
        https.socket = ctx.wrap_socket(https.socket, server_side=True)
        servers.append(https)
        print(f"  LAN/HTTPS at https://<this-pc's-lan-ip>:{HTTPS_PORT}")
    print()

    threads = [threading.Thread(target=serve, args=(s,), daemon=True) for s in servers]
    for t in threads:
        t.start()
    try:
        for t in threads:
            t.join()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
