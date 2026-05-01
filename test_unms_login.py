#!/usr/bin/env python3
"""
Test script to validate UNMS user credentials against the database
"""
import os
import sys
import getpass
from datetime import datetime

import psycopg2
import bcrypt

# Database config
DB_HOST = os.getenv('DB_HOST', 'unms-postgres')
DB_PORT = os.getenv('DB_PORT', '5432')
DB_NAME = os.getenv('DB_NAME', 'unms')
DB_USER = os.getenv('DB_USER', 'unms')
DB_PASS = None

# Read password from pgpass.txt (injected by container)
pgpass_file = '/container-data/pgpass.txt'
if os.path.exists(pgpass_file):
  with open(pgpass_file) as f:
    DB_PASS = f.read().strip()

if DB_PASS is None:
  DB_PASS = os.getenv('DB_PASS', '')


def get_user_from_db(username):
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
    return result
  except Exception as e:
    print(f"[ERROR] Database connection failed: {str(e)}")
    return None


def verify_password(password, hashed):
  """Verify password against bcrypt hash"""
  try:
    return bcrypt.checkpw(password.encode(), hashed.encode())
  except Exception as e:
    print(f"[ERROR] Password verification failed: {str(e)}")
    return False


def main():
  print("=" * 60)
  print("  UNMS User Credential Tester")
  print("=" * 60)
  print()
  
  # Get username
  username = input("Username: ").strip()
  if not username:
    print("[ERROR] Username cannot be empty")
    return 1
  
  # Get password (hidden input)
  password = getpass.getpass("Password: ")
  if not password:
    print("[ERROR] Password cannot be empty")
    return 1
  
  print()
  print("[*] Checking credentials...")
  print()
  
  # Query database
  user = get_user_from_db(username)
  
  if user is None:
    print(f"[FAIL] User '{username}' not found in database")
    return 1
  
  user_id, user_username, email, password_hash, role = user
  
  print(f"[*] User found: {user_username}")
  print(f"    Email: {email}")
  print(f"    Role: {role}")
  print(f"    ID: {user_id}")
  print()
  
  # Verify password
  if verify_password(password, password_hash):
    print("[PASS] Password is CORRECT")
    print()
    print(f"Authenticated as: {user_username} ({role})")
    return 0
  else:
    print("[FAIL] Password is INCORRECT")
    return 1


if __name__ == '__main__':
  sys.exit(main())
