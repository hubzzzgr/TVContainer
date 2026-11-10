import pathlib
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SIZE = 2 * 1024 * 1024


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_response(404 if self.path == '/missing' else 200)
        if self.path != '/unknown':
            self.send_header('Content-Length', str(SIZE))
        self.end_headers()
        try:
            for _ in range(SIZE // 32768):
                self.wfile.write(b'x' * 32768)
                self.wfile.flush()
                time.sleep(0.03 if self.path == '/slow' else 0.004)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
pathlib.Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
