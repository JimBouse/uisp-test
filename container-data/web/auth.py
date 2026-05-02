"""
UNMS user authentication module with brute force prevention
"""
import base64
import time
import psycopg2
import bcrypt
from typing import Optional, Tuple
from threading import Lock

DB_HOST = "unms-postgres"
DB_PORT = "5432"
DB_NAME = "unms"
DB_USER = "unms"
DB_PASS = None

# Read password from pgpass.txt
pgpass_file = '/container-data/pgpass.txt'
if __import__('os').path.exists(pgpass_file):
  with open(pgpass_file) as f:
    DB_PASS = f.read().strip()

if DB_PASS is None:
  DB_PASS = __import__('os').getenv('DB_PASS', '')

# Brute force prevention
MAX_FAILED_ATTEMPTS = 5
LOCKOUT_DURATION = 300  # 5 minutes in seconds
_failed_attempts = {}  # Format: {"ip:username": {"count": N, "timestamp": T}}
_attempt_lock = Lock()


def decode_basic_auth(auth_header: Optional[str]) -> Tuple[Optional[str], Optional[str]]:
  """Decode Authorization: Basic header"""
  if not auth_header or not auth_header.startswith('Basic '):
    return None, None
  try:
    encoded = auth_header[6:]  # Remove 'Basic '
    decoded = base64.b64decode(encoded).decode('utf-8')
    username, password = decoded.split(':', 1)
    return username, password
  except:
    return None, None


def get_user_from_db(username: str) -> Optional[dict]:
  """Query the user table for a given username"""
  try:
    conn = psycopg2.connect(
      host=DB_HOST,
      port=DB_PORT,
      dbname=DB_NAME,
      user=DB_USER,
      password=DB_PASS,
    )
    cursor = conn.cursor()
    
    # Try different schema locations
    schemas = ['unms', 'public', 'ucrm']
    result = None
    
    for schema in schemas:
      try:
        cursor.execute(
          f"SELECT id, username, email, password, role FROM {schema}.\"user\" WHERE username = %s",
          (username,)
        )
        result = cursor.fetchone()
        if result:
          break
      except psycopg2.errors.UndefinedTable:
        continue
    
    cursor.close()
    conn.close()
    
    if result:
      return {
        "id": result[0],
        "username": result[1],
        "email": result[2],
        "password_hash": result[3],
        "role": result[4]
      }
    return None
  except Exception as e:
    print(f"[ERROR] Database error: {str(e)}")
    return None


def verify_password(password: str, hashed: str) -> bool:
  """Verify password against bcrypt hash"""
  try:
    return bcrypt.checkpw(password.encode(), hashed.encode())
  except Exception as e:
    print(f"[ERROR] Password verification failed: {str(e)}")
    return False


def is_account_locked(key: str) -> bool:
  """Check if account is locked due to too many failed attempts"""
  with _attempt_lock:
    if key not in _failed_attempts:
      return False
    
    attempt_data = _failed_attempts[key]
    elapsed = time.time() - attempt_data['timestamp']
    
    # If lockout period has passed, reset
    if elapsed > LOCKOUT_DURATION:
      del _failed_attempts[key]
      return False
    
    # Still locked if count exceeded
    return attempt_data['count'] >= MAX_FAILED_ATTEMPTS


def record_failed_attempt(key: str):
  """Record a failed login attempt"""
  with _attempt_lock:
    if key not in _failed_attempts:
      _failed_attempts[key] = {"count": 0, "timestamp": time.time()}
    
    _failed_attempts[key]['count'] += 1
    _failed_attempts[key]['timestamp'] = time.time()


def clear_failed_attempts(key: str):
  """Clear failed attempts on successful login"""
  with _attempt_lock:
    if key in _failed_attempts:
      del _failed_attempts[key]


def authenticate_user(username: str, password: str, client_ip: str = "unknown") -> Optional[dict]:
  """Authenticate user credentials against UNMS database"""
  key = f"{client_ip}:{username}"
  
  # Check if account is locked
  if is_account_locked(key):
    return None
  
  user = get_user_from_db(username)
  if not user:
    record_failed_attempt(key)
    return None
  
  if verify_password(password, user['password_hash']):
    clear_failed_attempts(key)
    # Return user info without password hash
    return {
      "id": user['id'],
      "username": user['username'],
      "email": user['email'],
      "role": user['role']
    }
  else:
    record_failed_attempt(key)
    return None
  
  return None
