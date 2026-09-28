#!/usr/bin/env python3
"""IBKR public endpoint diagnostics through an explicit HTTP proxy; no account access."""
import argparse, concurrent.futures, json, socket, ssl, time, urllib.parse, urllib.request

WEB_HOSTS = ("download2.interactivebrokers.com", "download.interactivebrokers.com", "www.interactivebrokers.com", "download.ibkr.com.cn")
GATEWAYS = ("mcgw1.ibllc.com.cn", "mcgw1-hb1.ibllc.com.cn", "ndc1.ibllc.com", "hdc1.ibllc.com")

def probe(proxy, host, port, https=False):
    start = time.monotonic()
    out = {"host": host, "port": port, "proxy_used": True}
    sock = None
    try:
        sock = socket.create_connection((proxy.hostname, proxy.port or 8080), timeout=10)
        target = f"{host}:{port}"
        sock.sendall(f"CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n".encode())
        header = bytearray()
        while not header.endswith(b"\r\n\r\n"):
            data = sock.recv(1)
            if not data:
                raise ConnectionError("proxy_closed")
            header.extend(data)
            if len(header) > 16384:
                raise ConnectionError("proxy_header_too_large")
        status = bytes(header).split(b"\r\n", 1)[0].decode("ascii", "replace")
        if len(status.split()) < 2 or status.split()[1] != "200":
            raise ConnectionError("proxy_connect_" + status.split()[1])
        out["connect_ms"] = round((time.monotonic() - start) * 1000)
        if https:
            sock = ssl.create_default_context().wrap_socket(sock, server_hostname=host)
            out["tls_verified"] = True
            sock.sendall(f"HEAD / HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n".encode())
            line = bytearray()
            while not line.endswith(b"\r\n"):
                data = sock.recv(1)
                if not data:
                    break
                line.extend(data)
                if len(line) > 1024:
                    raise ConnectionError("http_status_too_large")
            fields = bytes(line).decode("ascii", "replace").split()
            if len(fields) < 2:
                raise ConnectionError("no_http_response")
            out["http_status"] = int(fields[1])
        out["ok"] = True
    except ssl.SSLCertVerificationError:
        out.update(ok=False, error="certificate_verification_failed")
    except (socket.timeout, TimeoutError):
        out.update(ok=False, error="timeout")
    except Exception as exc:
        # Do not print arbitrary exception messages, URLs, credentials or headers.
        out.update(ok=False, error=type(exc).__name__)
    finally:
        if sock is not None:
            sock.close()
    out["elapsed_ms"] = round((time.monotonic() - start) * 1000)
    return out

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--proxy", default="http://127.0.0.1:1082")
    parser.add_argument("--rounds", type=int, default=3)
    args = parser.parse_args()
    proxy = urllib.parse.urlsplit(args.proxy)
    if proxy.scheme != "http" or not proxy.hostname or proxy.username or proxy.password:
        parser.error("use an HTTP proxy URL without credentials")
    if not 1 <= args.rounds <= 20:
        parser.error("rounds must be between 1 and 20")
    failed = False
    jobs = [(host, 443, True) for host in WEB_HOSTS] + [(host, 4000, False) for host in GATEWAYS]
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        for n in range(args.rounds):
            futures = [pool.submit(probe, proxy, *job) for job in jobs]
            for future in futures:
                result = future.result()
                result["round"] = n + 1
                print(json.dumps(result, ensure_ascii=False), flush=True)
                failed |= not result["ok"]
    raise SystemExit(1 if failed else 0)

if __name__ == "__main__":
    main()
