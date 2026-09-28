import importlib.util
import ssl
import unittest
from pathlib import Path
from unittest import mock
from urllib.parse import urlsplit


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "ibkr-network-check.py"
SPEC = importlib.util.spec_from_file_location("ibkr_network_check", SCRIPT)
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)


class ProxySocket:
    def __init__(self, response):
        self.response = bytearray(response)
        self.sent = []
        self.closed = False

    def sendall(self, data):
        self.sent.append(data)

    def recv(self, count):
        part = bytes(self.response[:count])
        del self.response[:count]
        return part

    def close(self):
        self.closed = True


class NetworkCheckTests(unittest.TestCase):
    def test_proxy_503_is_a_failure_and_never_falls_back_direct(self):
        sock = ProxySocket(b"HTTP/1.1 503 Service Unavailable\r\n\r\n")
        with mock.patch.object(check.socket, "create_connection", return_value=sock) as connect:
            result = check.probe(urlsplit("http://127.0.0.1:1082"), "ndc1.ibllc.com", 4000)
        self.assertFalse(result["ok"])
        connect.assert_called_once_with(("127.0.0.1", 1082), timeout=10)
        self.assertTrue(sock.closed)

    def test_certificate_error_is_reported_without_raw_error_or_retry(self):
        sock = ProxySocket(b"HTTP/1.1 200 Connection established\r\n\r\n")
        context = mock.Mock()
        context.wrap_socket.side_effect = ssl.SSLCertVerificationError("private diagnostic details")
        with mock.patch.object(check.socket, "create_connection", return_value=sock), mock.patch.object(
            check.ssl, "create_default_context", return_value=context
        ):
            result = check.probe(urlsplit("http://127.0.0.1:1082"), "download2.interactivebrokers.com", 443, True)
        self.assertEqual(result["error"], "certificate_verification_failed")
        self.assertNotIn("private diagnostic", str(result))
        self.assertFalse(result["ok"])
        self.assertTrue(sock.closed)

    def test_https_probe_uses_hostname_validation_and_only_public_head_request(self):
        sock = ProxySocket(b"HTTP/1.1 200 Connection established\r\n\r\nHTTP/1.1 403 Forbidden\r\n")
        context = mock.Mock()
        context.wrap_socket.return_value = sock
        with mock.patch.object(check.socket, "create_connection", return_value=sock), mock.patch.object(
            check.ssl, "create_default_context", return_value=context
        ):
            result = check.probe(urlsplit("http://127.0.0.1:1082"), "www.interactivebrokers.com", 443, True)
        context.wrap_socket.assert_called_once_with(sock, server_hostname="www.interactivebrokers.com")
        self.assertTrue(result["tls_verified"])
        self.assertEqual(result["http_status"], 403)
        self.assertTrue(result["ok"])
        self.assertTrue(sock.sent[1].startswith(b"HEAD / HTTP/1.1\r\n"))


if __name__ == "__main__":
    unittest.main()
