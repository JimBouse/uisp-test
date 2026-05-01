#!/usr/bin/env python3
import os
from datetime import datetime

import pandas as pd
import psycopg2

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

QUERY = """
SELECT
  COALESCE(ser.address_gps_lat, s.latitude) lat,
  COALESCE(ser.address_gps_lon, s.longitude) lon,
  regexp_replace(s.name, '\\.[a-zA-Z0-9,!?]', '', 'g') as name,
  s.updated_at as offline_since,
  ser.service_id,
  coalesce(d.data->>'port', 'Unknown') as upstream_port,
  coalesce(p.hostname, 'Unknown') as upstream_hostname,
  coalesce(split_part(p.ip::varchar, '/', 1), 'Unknown') as upstream_ip
FROM
  unms.site s,
  ucrm.service ser,
  ucrm.service_attribute sa,
  unms.device d,
  unms.device p
WHERE
  d.parent_id = p.device_id AND
  LOWER(d.mac::text) = LOWER(sa.value) AND
  s.ucrm_id::integer = ser.service_id AND
  ser.service_id = sa.service_id AND
  ser.status = 1 AND
  sa.attribute_id = 2 AND
  s.status = 'disconnected' AND
  s.type = 'endpoint' AND
  ser.client_id NOT IN (SELECT client_id FROM ucrm.client WHERE has_overdue_invoice = true) AND
  ser.service_id NOT IN (SELECT service_id FROM ucrm.service_attribute WHERE attribute_id = 36 AND value::int = 1) AND
  s.updated_at > NOW() - INTERVAL '30 days'
ORDER BY s.updated_at DESC
"""


def fetch_data():
  conn = psycopg2.connect(
    host=DB_HOST,
    port=DB_PORT,
    dbname=DB_NAME,
    user=DB_USER,
    password=DB_PASS,
  )
  df = pd.read_sql_query(QUERY, conn)
  conn.close()
  return df


def main():
  print(f"[{datetime.now()}] Fetching data...")
  df = fetch_data()
  df.to_csv('/container-data/unms_status.csv', index=False)
  print(df)


if __name__ == '__main__':
  main()
