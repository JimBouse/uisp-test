"""
UNMS user authentication module
"""
import base64
import psycopg2
import bcrypt
from typing import Optional, Tuple

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


def authenticate_user(username: str, password: str) -> Optional[dict]:
  """Authenticate user credentials against UNMS database"""
  user = get_user_from_db(username)
  if not user:
    return None
  
  if verify_password(password, user['password_hash']):
    # Return user info without password hash
    return {
      "id": user['id'],
      "username": user['username'],
      "email": user['email'],
      "role": user['role']
    }
  
  return None
