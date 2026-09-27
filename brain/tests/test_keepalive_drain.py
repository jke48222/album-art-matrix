"""Every POST leaves its kept-alive connection ready for the next request,
even a route that answers without reading its body."""
import http.client
import socket

import pytest

from brain.control import ControlState, serve


@pytest.fixture
def wall():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    ctrl = ControlState(frame_len=64 * 64 * 3)
    httpd = serve(ctrl, port)
    try:
        yield ctrl, port
    finally:
        httpd.shutdown()
        httpd.server_close()


def ask(conn, method, path, body=None):
    headers = {"Content-Type": "application/json"} if body is not None else {}
    conn.request(method, path, body=body, headers=headers)
    response = conn.getresponse()
    return response.status, response.read()


# Routes that answer before they read, with the features behind them off
# (a fresh ControlState builds none of them).
@pytest.mark.parametrize("path", ["/weather/refresh", "/weather/place", "/shelf/sync",
                                  "/video/stop", "/homekit/show", "/pictures/check",
                                  "/no/such/route"])
def test_the_next_request_on_the_socket_still_works(wall, path):
    _, port = wall
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        ask(conn, "POST", path, b'{"query": "Atlanta, a long enough body to notice"}')
        sock = conn.sock
        status, _ = ask(conn, "GET", "/state")
        assert status == 200
        assert conn.sock is sock        # the same connection, not a reconnect
    finally:
        conn.close()


def test_a_body_too_large_to_drain_closes_the_connection(wall, monkeypatch):
    _, port = wall
    monkeypatch.setattr("brain.control.BODY_MAX", 16)
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        status, _ = ask(conn, "POST", "/state", b'{"brightness": 0.5, "pad": "xxxxxxxx"}')
        assert status == 413
        # A fresh request still works on a new connection.
        status, _ = ask(conn, "GET", "/state")
        assert status == 200
    finally:
        conn.close()
