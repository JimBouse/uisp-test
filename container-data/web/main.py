#!/usr/bin/env python3
"""
FastAPI-based HTTPS web server for UISP Helper tools
Provides on-demand polling of offline devices with Basic Auth
"""
import os
import csv
import time
import logging
import subprocess
from datetime import datetime
from logging.handlers import RotatingFileHandler
from typing import Optional, Dict, List
from threading import Lock

from fastapi import FastAPI, HTTPException, Header, Request, Form
from fastapi.responses import FileResponse, HTMLResponse
import uvicorn
from mako.template import Template

from auth import decode_basic_auth, authenticate_user

# === Logging Setup ===
log_dir = "/container-data/logs"
os.makedirs(log_dir, exist_ok=True)

log_file = os.path.join(log_dir, "https.log")
handler = RotatingFileHandler(log_file, maxBytes=10_000_000, backupCount=5)
formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
handler.setFormatter(formatter)

logger = logging.getLogger("uisp_helper")
logger.addHandler(handler)
logger.setLevel(logging.INFO)

# === Cache Setup ===
_cache_time: Optional[float] = None
_cache_data: Optional[Dict] = None
_cache_lock = Lock()
CACHE_TTL = 10  # 10 seconds

# === FastAPI App Setup ===
app = FastAPI(title="UISP Helper", version="2.0")

# Setup templates directory
templates_dir = "/container-data/web/templates"
os.makedirs(templates_dir, exist_ok=True)


def require_auth(f):
  """Decorator to require Basic Auth"""
  async def wrapper(*args, **kwargs):
    request: Request = kwargs.get('request')
    auth_header = request.headers.get('Authorization')
    username, password = decode_basic_auth(auth_header)
    
    if not username or not password:
      logger.warning(f"Missing credentials from {request.client.host}")
      raise HTTPException(status_code=401, detail="Unauthorized", headers={"WWW-Authenticate": "Basic realm=UNMS"})
    
    user = authenticate_user(username, password)
    if not user:
      logger.warning(f"Failed login attempt for user: {username}")
      raise HTTPException(status_code=401, detail="Invalid credentials", headers={"WWW-Authenticate": "Basic realm=UNMS"})
    
    # Store user in kwargs for the handler
    kwargs['current_user'] = user
    return await f(*args, **kwargs)
  
  return wrapper


def refresh_cache():
  """Refresh cache by running poll_unms_status.py"""
  try:
    poll_script = "/container-data/poll_unms_status.py"
    if os.path.exists(poll_script):
      subprocess.run(['/usr/bin/python3', poll_script], 
                    timeout=30, 
                    capture_output=True, 
                    check=False)
      global _cache_time
      with _cache_lock:
        _cache_time = time.time()
      logger.info("Cache refreshed")
  except Exception as e:
    logger.error(f"Error refreshing cache: {str(e)}")


def get_cached_data():
  """Get cached data if valid, refresh if expired"""
  global _cache_time
  with _cache_lock:
    current_time = time.time()
    if _cache_time is None or (current_time - _cache_time) > CACHE_TTL:
      # Need to refresh - release lock first
      pass
    else:
      return True  # Cache is still valid
  
  # Outside lock, refresh cache
  refresh_cache()
  return False


@app.get("/")
async def index(request: Request):
  """Public status page (no auth required)"""
  hostname = request.url.hostname or "localhost"
  port = request.url.port or 9443
  
  template_path = "/container-data/web/templates/status.html"
  with open(template_path, "r") as f:
    template = Template(f.read())
  
  html = template.render(hostname=hostname, port=port)
  return HTMLResponse(content=html, status_code=200)


@app.get("/status")
async def status(request: Request, authorization: Optional[str] = Header(None), current_user: dict = None):
  """Get JSON status (requires auth)"""
  # Check auth
  username, password = decode_basic_auth(authorization)
  if not username or not password:
    logger.warning(f"Missing credentials from {request.client.host}")
    raise HTTPException(status_code=401, detail="Unauthorized", headers={"WWW-Authenticate": "Basic realm=UNMS"})
  
  user = authenticate_user(username, password, request.client.host)
  if not user:
    logger.warning(f"Failed login attempt for user: {username} from {request.client.host}")
    raise HTTPException(status_code=401, detail="Invalid credentials", headers={"WWW-Authenticate": "Basic realm=UNMS"})
  
  csv_exists = os.path.exists("/container-data/unms_status.csv")
  
  return {
    "container": os.environ.get("HOSTNAME", "uisp-tester"),
    "port": int(os.environ.get("UISP_HELPER_PORT", 9443)),
    "service": "uisp-helper",
    "version": "2.0",
    "authenticated_as": user['username'],
    "role": user['role'],
    "data_available": csv_exists,
    "timestamp": datetime.now().isoformat(),
  }


@app.get("/offline-devices")
async def offline_devices_csv(request: Request, authorization: Optional[str] = Header(None)):
  """Download offline devices as CSV (requires auth)"""
  # Check auth
  username, password = decode_basic_auth(authorization)
  if not username or not password:
    logger.warning(f"Missing credentials from {request.client.host}")
    raise HTTPException(status_code=401, detail="Unauthorized", headers={"WWW-Authenticate": "Basic realm=UNMS"})
  
  user = authenticate_user(username, password, request.client.host)
  if not user:
    logger.warning(f"Failed login attempt for user: {username} from {request.client.host}")
    raise HTTPException(status_code=401, detail="Invalid credentials", headers={"WWW-Authenticate": "Basic realm=UNMS"})
  
  csv_path = "/container-data/unms_status.csv"
  
  # Refresh cache if needed
  get_cached_data()
  
  if os.path.exists(csv_path):
    logger.info(f"CSV download by {user['username']}")
    return FileResponse(csv_path, media_type="text/csv", filename="unms_status.csv")
  
  logger.warning("CSV file not found")
  raise HTTPException(status_code=404, detail="Data file not found. Polling may not have run yet.")


@app.get("/offline-devices.json")
async def offline_devices_json(request: Request, authorization: Optional[str] = Header(None)):
  """Get offline devices as JSON (requires auth)"""
  # Check auth
  username, password = decode_basic_auth(authorization)
  if not username or not password:
    logger.warning(f"Missing credentials from {request.client.host}")
    raise HTTPException(status_code=401, detail="Unauthorized", headers={"WWW-Authenticate": "Basic realm=UNMS"})
  
  user = authenticate_user(username, password, request.client.host)
  if not user:
    logger.warning(f"Failed login attempt for user: {username} from {request.client.host}")
    raise HTTPException(status_code=401, detail="Invalid credentials", headers={"WWW-Authenticate": "Basic realm=UNMS"})
  
  csv_path = "/container-data/unms_status.csv"
  
  # Refresh cache if needed
  get_cached_data()
  
  if not os.path.exists(csv_path):
    logger.warning("CSV file not found")
    raise HTTPException(status_code=404, detail="Data file not found. Polling may not have run yet.")
  
  try:
    devices = []
    with open(csv_path, "r") as f:
      reader = csv.DictReader(f)
      for row in reader:
        devices.append(row)
    
    logger.info(f"JSON request by {user['username']} - {len(devices)} devices")
    
    return {
      "count": len(devices),
      "devices": devices,
      "requested_by": user['username'],
      "role": user['role'],
      "generated": datetime.now().isoformat(),
      "cached": (time.time() - _cache_time) < CACHE_TTL if _cache_time else False
    }
  except Exception as e:
    logger.error(f"Error parsing CSV: {str(e)}")
    raise HTTPException(status_code=500, detail=f"Error parsing data: {str(e)}")


@app.get("/login")
async def login_form(request: Request):
  """Login form page"""
  try:
    template_path = "/container-data/web/templates/login.html"
    with open(template_path, "r") as f:
      html = f.read()
    return HTMLResponse(content=html, status_code=200)
  except Exception as e:
    logger.error(f"Error rendering login page: {str(e)}")
    return HTMLResponse("""
      <html>
        <head><title>Login - UISP Helper</title></head>
        <body style="font-family: sans-serif; padding: 20px;">
          <h1>UISP Helper Login</h1>
          <form method="post" action="/login">
            <div>
              <label>Username: <input type="text" name="username" required></label>
            </div>
            <div>
              <label>Password: <input type="password" name="password" required></label>
            </div>
            <button type="submit">Login</button>
          </form>
        </body>
      </html>
    """, status_code=200)


@app.post("/login")
async def login_submit(request: Request, username: str = Form(...), password: str = Form(...)):
  """Handle login form submission"""
  user = authenticate_user(username, password, request.client.host)
  if not user:
    logger.warning(f"Failed form login for user: {username} from {request.client.host}")
    return HTMLResponse("""
      <html>
        <head><title>Login Failed - UISP Helper</title></head>
        <body style="font-family: sans-serif; padding: 20px;">
          <h1>Login Failed</h1>
          <p style="color: red;">Invalid username or password. Your account may be temporarily locked after too many failed attempts.</p>
          <a href="/login">Try Again</a> | <a href="/">Back to Home</a>
        </body>
      </html>
    """, status_code=401)
  
  logger.info(f"Successful form login for user: {username} from {request.client.host}")
  
  # Extract hostname and port for display
  hostname = request.url.hostname or "localhost"
  port = request.url.port or 9443
  
  return HTMLResponse(f"""
    <html>
      <head><title>Login Success - UISP Helper</title></head>
      <body style="font-family: sans-serif; padding: 20px;">
        <h1>Welcome!</h1>
        <p>You have successfully logged in.</p>
        <p>For API access, use HTTP Basic Auth with your UNMS credentials:</p>
        <pre>curl -k --user username:password https://{hostname}:{port}/offline-devices</pre>
        <a href="/">Back to Home</a>
      </body>
    </html>
  """, status_code=200)


@app.get("/health")
async def health():
  """Health check endpoint (no auth)"""
  return {"status": "ok"}


if __name__ == "__main__":
  port = int(os.environ.get("UISP_HELPER_PORT", 9443))
  
  # Check for certificates
  cert_file = "/cert/live.crt"
  key_file = "/cert/live.key"
  
  if not os.path.exists(cert_file) or not os.path.exists(key_file):
    logger.error(f"SSL certificates not found at /cert")
    exit(1)
  
  logger.info(f"Starting UISP Helper on port {port}")
  
  uvicorn.run(
    app,
    host="0.0.0.0",
    port=port,
    ssl_certfile=cert_file,
    ssl_keyfile=key_file,
    log_config=None
  )
