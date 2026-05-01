#!/usr/bin/env python3
"""
Simple HTTPS web server for uisp-helper tools
Serves on port 9080 and provides status and data endpoints
Uses UNMS Let's Encrypt certificates for SSL/TLS
"""

import os
import json
import ssl
import time
import subprocess
import csv
from http.server import HTTPServer, BaseHTTPRequestHandler
from datetime import datetime
from threading import Lock


class UISPHelperHandler(BaseHTTPRequestHandler):
    """HTTP request handler for uisp-helper endpoints"""
    
    # Cache variables for offline devices (10 second TTL)
    _cache_time = None
    _cache_data = None
    _cache_lock = Lock()
    CACHE_TTL = 10  # 10 seconds

    def do_GET(self):
        """Handle GET requests"""
        if self.path == "/" or self.path == "":
            self.send_status_page()
        elif self.path == "/status":
            self.send_json_response(self.get_status())
        elif self.path == "/offline-devices":
            self.send_csv_file()
        elif self.path == "/offline-devices.json":
            self.send_json_file()
        else:
            self.send_error(404, "Not Found")

    def send_status_page(self):
        """Send HTML status page"""
        status = self.get_status()
        
        html = f"""
<!DOCTYPE html>
<html>
<head>
    <title>UISP Helper - Status</title>
    <style>
        body {{ font-family: Arial, sans-serif; margin: 20px; background: #f5f5f5; }}
        .container {{ background: white; padding: 20px; border-radius: 5px; max-width: 800px; }}
        h1 {{ color: #333; }}
        .endpoint {{ background: #f0f0f0; padding: 10px; margin: 10px 0; border-left: 4px solid #0066cc; }}
        .status {{ color: green; font-weight: bold; }}
        .csv-link {{ color: #0066cc; text-decoration: none; }}
        table {{ border-collapse: collapse; width: 100%; margin-top: 20px; }}
        th, td {{ border: 1px solid #ddd; padding: 8px; text-align: left; }}
        th {{ background-color: #0066cc; color: white; }}
    </style>
</head>
<body>
    <div class="container">
        <h1>UISP Helper</h1>
        <p>Simple web server for UISP utility tools</p>
        
        <h2>Status</h2>
        <table>
            <tr><td>Status</td><td><span class="status">✓ Running</span></td></tr>
            <tr><td>Container</td><td>{status.get('container', 'uisp-tester')}</td></tr>
            <tr><td>Port</td><td>9443</td></tr>
            <tr><td>Started</td><td>{status.get('started', 'unknown')}</td></tr>
        </table>
        
        <h2>Available Endpoints</h2>
        <div class="endpoint">
            <strong>/status</strong><br>
            JSON status response
        </div>
        <div class="endpoint">
            <strong>/offline-devices</strong><br>
            CSV file of offline devices
        </div>
        <div class="endpoint">
            <strong>/offline-devices.json</strong><br>
            JSON format of offline devices
        </div>
        
        <h2>Access via HTTPS</h2>
        <p>These endpoints are accessible through HTTPS at:</p>
        <pre>https://your-host:9080/status
https://your-host:9080/offline-devices
https://your-host:9080/offline-devices.json</pre>
    </div>
</body>
</html>
"""
        
        self.send_response(200)
        self.send_header("Content-type", "text/html")
        self.end_headers()
        self.wfile.write(html.encode())

    def refresh_cache(self):
        """Refresh cache by running poll_unms_status.py"""
        try:
            poll_script = "/container-data/poll_unms_status.py"
            if os.path.exists(poll_script):
                subprocess.run(['/usr/bin/python3', poll_script], 
                              timeout=30, 
                              capture_output=True, 
                              check=False)
                UISPHelperHandler._cache_time = time.time()
        except Exception as e:
            print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] Error refreshing cache: {str(e)}")
    
    def get_cached_data(self):
        """Get cached data if valid, refresh if expired"""
        with UISPHelperHandler._cache_lock:
            current_time = time.time()
            # If no cache or cache expired, refresh
            if (UISPHelperHandler._cache_time is None or 
                current_time - UISPHelperHandler._cache_time > UISPHelperHandler.CACHE_TTL):
                self.refresh_cache()
    
    def send_csv_file(self):
        """Send CSV file of offline devices"""
        csv_path = "/container-data/unms_status.csv"
        
        # Refresh cache if needed
        self.get_cached_data()
        
        if os.path.exists(csv_path):
            try:
                with open(csv_path, "rb") as f:
                    content = f.read()
                self.send_response(200)
                self.send_header("Content-type", "text/csv")
                self.send_header("Content-Disposition", "attachment; filename=unms_status.csv")
                self.end_headers()
                self.wfile.write(content)
                return
            except Exception as e:
                self.send_json_response({
                    "error": f"Failed to read CSV: {str(e)}"
                }, status=500)
                return
        
        self.send_json_response({
            "error": "CSV file not found",
            "path": csv_path,
            "message": "The polling script may not have run yet"
        }, status=404)

    def send_json_file(self):
        """Send JSON representation of offline devices"""
        csv_path = "/container-data/unms_status.csv"
        
        # Refresh cache if needed
        self.get_cached_data()
        
        if not os.path.exists(csv_path):
            self.send_json_response({
                "error": "Data file not found",
                "message": "The polling script may not have run yet"
            }, status=404)
            return
        
        try:
            devices = []
            with open(csv_path, "r") as f:
                reader = csv.DictReader(f)
                for row in reader:
                    devices.append(row)
            
            self.send_json_response({
                "count": len(devices),
                "devices": devices,
                "generated": datetime.now().isoformat(),
                "cached": True
            })
        except Exception as e:
            self.send_json_response({
                "error": f"Failed to parse CSV: {str(e)}"
            }, status=500)

    def send_json_response(self, data, status=200):
        """Send JSON response"""
        self.send_response(status)
        self.send_header("Content-type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data, indent=2).encode())

    def get_status(self):
        """Get server status info"""
        return {
            "container": os.environ.get("HOSTNAME", "uisp-tester"),
            "started": datetime.now().isoformat(),
            "port": 9443,
            "service": "uisp-helper",
            "version": "1.0"
        }

    def log_message(self, format, *args):
        """Override to customize logging"""
        timestamp = datetime.now().strftime("[%Y-%m-%d %H:%M:%S]")
        print(f"{timestamp} {format % args}")


def main():
    """Start the HTTPS web server"""
    port = int(os.environ.get("UISP_HELPER_PORT", 9443))
    host = "0.0.0.0"
    
    # Ensure pgpass.txt exists (needed by poll_unms_status.py)
    if not os.path.exists("/container-data/pgpass.txt"):
        print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] WARNING: pgpass.txt not found - polling will fail")
    
    # UNMS Let's Encrypt certificate paths
    cert_dir = "/cert"
    cert_file = os.path.join(cert_dir, "live.crt")
    key_file = os.path.join(cert_dir, "live.key")
    
    # Check if certificates exist
    if not os.path.exists(cert_file) or not os.path.exists(key_file):
        print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] ERROR: SSL certificates not found at {cert_dir}")
        print(f"  Certificate: {cert_file}")
        print(f"  Key: {key_file}")
        print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] Make sure /cert is mounted from UNMS installation")
        return 1
    
    server_address = (host, port)
    httpd = HTTPServer(server_address, UISPHelperHandler)
    
    # Setup SSL/TLS
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert_file, key_file)
    httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
    
    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] UISP Helper starting on {host}:{port} (HTTPS)")
    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] Using SSL certificates from {cert_dir}")
    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] Access at https://localhost:{port}/")
    
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print(f"\n[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] Server shutting down...")
        httpd.server_close()
    
    return 0


if __name__ == "__main__":
    exit(main())
