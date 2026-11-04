#!/usr/bin/env python3
"""Background poll-INSERT simulator for merge-under-load PoC."""
import subprocess
import time

lat_path = "/tmp/insert_lat_ms.txt"
err_path = "/tmp/insert_err.txt"
open(lat_path, "w").close()
open(err_path, "w").close()

n = 250
for i in range(1, n + 1):
    sql = f"""
    INSERT INTO xgb_dashopnvpn."VpnServerClientTraffics"
      ("VpnServerId","ExternalId","SessionId","BytesReceived","BytesSent","MeasuredAt","UserId")
    VALUES (
      1, 'poc-poll-load',
      ('00000000-0000-4000-8000-' || lpad(to_hex({1000000 + i}), 12, '0'))::uuid,
      {1000 + i}, {500 + i}, clock_timestamp(), NULL
    );
    """
    t0 = time.perf_counter()
    r = subprocess.run(
        ["psql", "-U", "datagate", "-d", "timescale_poc", "-v", "ON_ERROR_STOP=1", "-q", "-c", sql],
        capture_output=True,
        text=True,
    )
    ms = (time.perf_counter() - t0) * 1000
    with open(lat_path, "a", encoding="utf-8") as f:
        f.write(f"{ms:.2f}\n")
    if r.returncode != 0:
        with open(err_path, "a", encoding="utf-8") as f:
            f.write(r.stderr + "\n")
    time.sleep(0.15)

open("/tmp/insert_done.flag", "w", encoding="utf-8").write("DONE\n")
