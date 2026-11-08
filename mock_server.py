import http.server
import socketserver
import json
import urllib.parse
import os

PORT = 8080
frontend_dir = os.path.join(os.path.dirname(__file__), 'frontend')

visits = 0

class MockHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=frontend_dir, **kwargs)

    def do_GET(self):
        global visits
        parsed_path = urllib.parse.urlparse(self.path)
        
        if parsed_path.path == '/api/info':
            visits += 1
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                'pod': 'mock-pod-1',
                'visits': visits,
                'served': visits,
                'uptime': 120,
                'redis': 'ok (mock)'
            }).encode())
            return
            
        if parsed_path.path == '/api/cluster':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                'pod': 'mock-pod-1',
                'pods': [
                    {
                        'name': 'mock-pod-1',
                        'app': 'backend',
                        'phase': 'Running',
                        'ready': True,
                        'reason': None,
                        'restarts': 0,
                        'node': 'mock-node',
                        'age': 100
                    },
                    {
                        'name': 'mock-frontend-1',
                        'app': 'frontend',
                        'phase': 'Running',
                        'ready': True,
                        'reason': None,
                        'restarts': 0,
                        'node': 'mock-node',
                        'age': 120
                    }
                ],
                'hpa': {
                    'current': 1,
                    'desired': 1,
                    'min': 1,
                    'max': 10,
                    'cpu': 15,
                    'target': 50
                }
            }).encode())
            return

        return super().do_GET()

    def do_POST(self):
        parsed_path = urllib.parse.urlparse(self.path)
        if parsed_path.path.startswith('/api/'):
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'status': 'mocked action'}).encode())
            return
            
        self.send_response(404)
        self.end_headers()

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("", PORT), MockHandler) as httpd:
    print("Serving mock app at http://localhost:" + str(PORT))
    httpd.serve_forever()
