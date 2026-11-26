"""How clients reach the speech daemon, on every platform.

The protocol is the same everywhere: a client connects, sends one JSON
object, reads one JSON object back until the daemon closes the connection.

  macOS / Linux  a unix socket at DATA_DIR/daemon.sock. Only this user can
                 open it, by file permissions.
  Windows        TCP on 127.0.0.1, an ephemeral port. Python has no unix
                 sockets on Windows, and loopback TCP is the one transport
                 both Python's standard library and .NET speak natively.
                 Any local process can open a loopback port, so the daemon
                 writes DATA_DIR/daemon.port as {"port": N, "token": "..."}
                 and refuses any request without that token. The file lives
                 in the user's own profile, so the token is as private as
                 the unix socket is.

BELLOWFLO_IPC=tcp forces the Windows transport anywhere, so it can be tested
on a Mac.

Standard library only (ktts and the hooks import it).
"""
import json
import os
import secrets
import socket
import sys

import bf_paths

SOCK_PATH = bf_paths.data("daemon.sock")
PORT_PATH = bf_paths.data("daemon.port")
_UNIX_PATH_MAX = 103          # macOS sun_path is 104 bytes, NUL included


def transport():
    forced = os.environ.get("BELLOWFLO_IPC")
    if forced in ("unix", "tcp"):
        return forced
    if sys.platform == "win32" or not hasattr(socket, "AF_UNIX"):
        return "tcp"
    # The macOS app speaks only the unix socket, so never fall back silently
    # there: an over-long path fails at bind, in the log, not as two sides
    # quietly using different transports.
    if sys.platform != "darwin" and len(SOCK_PATH.encode()) > _UNIX_PATH_MAX:
        return "tcp"
    return "unix"


# -- daemon side -------------------------------------------------------------

class Server:
    def __init__(self):
        bf_paths.ensure()
        self.kind = transport()
        self.token = None
        if self.kind == "unix":
            try:
                os.unlink(SOCK_PATH)
            except OSError:
                pass
            self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.sock.bind(SOCK_PATH)
        else:
            self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.sock.bind(("127.0.0.1", 0))
            self.token = secrets.token_hex(16)
            port = self.sock.getsockname()[1]
            bf_paths.write_atomic(PORT_PATH, json.dumps({"port": port, "token": self.token}))
        self.sock.listen(8)

    def accept(self):
        return self.sock.accept()[0]

    def authorised(self, req):
        return self.token is None or secrets.compare_digest(
            str(req.get("token", "")), self.token)


def cleanup():
    """Remove the endpoint file on the way out, so a client never trusts a
    port that some other program may since have taken."""
    for path in (SOCK_PATH, PORT_PATH):
        try:
            os.unlink(path)
        except OSError:
            pass


# -- client side -------------------------------------------------------------

def connect(timeout=None):
    """A connected socket, or OSError if no daemon is listening."""
    if transport() == "unix":
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        try:
            s.connect(SOCK_PATH)
        except OSError:
            s.close()
            raise
        return s
    port, _ = _port_and_token()
    return socket.create_connection(("127.0.0.1", port), timeout=timeout)


def _port_and_token():
    try:
        with open(PORT_PATH, encoding="utf-8") as f:
            info = json.load(f)
        return int(info["port"]), str(info["token"])
    except (OSError, ValueError, KeyError) as e:
        raise ConnectionRefusedError(f"no daemon endpoint: {e}")


def alive():
    if transport() == "unix":
        try:
            connect(timeout=1).close()
            return True
        except OSError:
            return False
    # Over TCP, something answering on the port is not proof it is us:
    # ask, and expect our own reply shape.
    try:
        return "ok" in request({"cmd": "status"}, timeout=2)
    except (OSError, ValueError):
        return False


def request(req, timeout=None):
    """Send one request and return the parsed reply."""
    if transport() == "tcp":
        req = dict(req, token=_port_and_token()[1])
    s = connect(timeout=timeout)
    try:
        s.sendall(json.dumps(req).encode())
        s.shutdown(socket.SHUT_WR)
        chunks = []
        while True:
            b = s.recv(1 << 16)
            if not b:
                break
            chunks.append(b)
    finally:
        s.close()
    reply = json.loads(b"".join(chunks).decode() or "{}")
    if not isinstance(reply, dict):
        raise ValueError("not a Bellow Flo daemon")
    return reply
