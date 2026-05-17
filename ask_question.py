import os
import io
import sys
import argparse
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from contextlib import redirect_stdout, redirect_stderr
from aider.main import main as aider_main

# Force unbuffered output at the interpreter level
os.environ["PYTHONUNBUFFERED"] = "1"

class LiveStream(io.StringIO):
    def __init__(self):
        super().__init__()
        self.terminal = sys.__stdout__
        self._lock = threading.Lock()

	# Fixed: encoding must be a property because it's read-only in base class
    @property
    def encoding(self):
        return self.terminal.encoding or 'utf-8'

    def isatty(self):
        # Trick rich/prompt_toolkit to enable interactive-like streaming
        return True

    def write(self, s):
        with self._lock:
            super().write(s)
        if s:
            # Write to the real stdout character by character for live feedback
            self.terminal.write(s)
            self.terminal.flush() 
        return len(s)

    def get_full_content(self):
        with self._lock:
            return self.getvalue()

def create_log_server(log_buffer, port=7976):
    class LogHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == '/logs':
                raw_content = log_buffer.get_full_content()
                if not raw_content:
                    raw_content = ""
                encoded_content = raw_content.encode('utf-8')
                content_length = len(encoded_content)
                
                self.send_response(200)
                self.send_header('Content-type', 'text/plain; charset=utf-8')
                self.send_header('Content-Length', str(content_length))
                self.send_header('X-Content-Type-Options', 'nosniff')
                self.send_header('Cache-Control', 'no-cache, no-store, must-revalidate')
                self.end_headers()
                
                self.wfile.write(encoded_content)
            else:
                self.send_response(404)
                self.end_headers()
        
        def log_message(self, format, *args): 
            return # Silence server logs

    server	 = ThreadingHTTPServer(('127.0.0.1', port), LogHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    return server, thread

def run_aider_from_python(cwd, api_key, message, model, files, http_port):
    os.chdir(cwd)
    os.environ["OPENROUTER_API_KEY"] = api_key
    
    live_output = LiveStream()
    server, server_thread = create_log_server(live_output, port=http_port)
    
    try:
        server_thread.start()
        print(f"=== Aider Live Logs: http://localhost:{http_port}/logs ===")
        print("=== Script START ===")

        args = [
            "--no-gitignore",
            "--no-auto-commits",
            "--no-pretty",
            "--yes",
            "--model", model,
            "--message", message,
        ]
        args.extend(files)

        # Redirect stdout and stderr to our LiveStream object
        with redirect_stdout(live_output), redirect_stderr(live_output):
            aider_main(argv=args)

    except SystemExit:
        pass 
    except Exception as e:
        sys.__stderr__.write(f"\nPYTHON CRITICAL ERROR: {e}\n")
    finally:
        print("\n=== Script END ===")
        if server:
            server.shutdown()
            server.server_close()

def _sanitize_arg(value: str) -> str:
	return value.strip().strip("'\"").strip() if value else ""

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--api-key", required=True)
    parser.add_argument("--message", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--port", type=int, default=7976)
    parser.add_argument("--files", nargs="+")
    
    args = parser.parse_args()

    run_aider_from_python(
        cwd=_sanitize_arg(args.cwd),
        api_key=_sanitize_arg(args.api_key),
        message=_sanitize_arg(args.message),
        model=_sanitize_arg(args.model),
        http_port=args.port,
        files=args.files or []
    )
