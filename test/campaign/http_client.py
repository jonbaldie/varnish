"""Campaign transport and JSON-compatible observations of real HTTP responses.

Header values are never discarded. get_all() returns individual field values;
get()/indexing return a newline-separated display value for repeated fields (not
an HTTP wire value). The same string-valued mapping is kept in report evidence.
"""
import http.client
import socket


class CampaignHeaders(dict):
    def __init__(self, pairs):
        self._values = {}
        self._names = {}
        for name, value in pairs:
            key = name.lower()
            self._names.setdefault(key, name)
            self._values.setdefault(key, []).append(value)
        super().__init__((self._names[key], "\n".join(values))
                         for key, values in self._values.items())

    def __getitem__(self, name):
        return super().__getitem__(self._names[name.lower()])

    def __contains__(self, name):
        return name.lower() in self._names

    def get(self, name, default=None):
        return self[name] if name in self else default

    def get_all(self, name):
        return list(self._values.get(name.lower(), ()))


class CampaignResponse(dict):
    """One shared observation shape, usable directly as campaign JSON evidence."""
    def __init__(self, status, headers, body):
        super().__init__(status=status, headers=CampaignHeaders(headers),
                         body=body.decode("utf-8", errors="replace"))
        self.update(x_cache=self.headers.get("X-Cache", ""),
                    backend_request_id=self.headers.get("X-Backend-Request-Id", ""),
                    set_cookie=self.headers.get("Set-Cookie"))

    @classmethod
    def from_report(cls, evidence):
        """Restore header access at the existing string-valued JSON boundary."""
        pairs = [(name, value) for name, display in evidence["headers"].items()
                 for value in display.split("\n")]
        return cls(evidence["status"], pairs, evidence["body"].encode("utf-8"))

    status = property(lambda self: self["status"])
    headers = property(lambda self: self["headers"])
    body = property(lambda self: self["body"])
    x_cache = property(lambda self: self["x_cache"])
    backend_request_id = property(lambda self: self["backend_request_id"])


class CampaignHttpClient:
    def __init__(self, host, port, timeout=5):
        self.host, self.port, self.timeout = host, port, timeout

    def send_raw(self, wire):
        """Send exact request bytes; parse the response without hiding timeouts."""
        try:
            with socket.create_connection((self.host, self.port), self.timeout) as sock:
                sock.sendall(wire)
                with http.client.HTTPResponse(sock) as response:
                    response.begin()
                    return self._read(response)
        except Exception as exc:
            raise RuntimeError(
                f"raw HTTP {self.host}:{self.port}: {type(exc).__name__}: {exc}"
            ) from exc

    def purge(self, path):
        response = self.request("PURGE", path)
        if response.status != 200:
            raise RuntimeError(
                f"PURGE http://{self.host}:{self.port}{path}: "
                f"status {response.status}: {response.body}"
            )
        return response

    @staticmethod
    def _read(response):
        return CampaignResponse(response.status, response.getheaders(), response.read())

    def request(self, method, path, headers=None, body=None):
        conn = http.client.HTTPConnection(self.host, self.port, timeout=self.timeout)
        try:
            conn.request(method, path, body=body, headers=headers or {})
            with conn.getresponse() as response:
                return self._read(response)
        except Exception as exc:
            raise RuntimeError(
                f"{method} http://{self.host}:{self.port}{path}: {type(exc).__name__}: {exc}"
            ) from exc
        finally:
            conn.close()
