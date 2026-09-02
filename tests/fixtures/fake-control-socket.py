#!/usr/bin/env python3
"""一次性的假控制端点:接受一个连接,回一行固定 JSON。

用法: fake-control-socket.py <socket 路径> <state>
"""
import os
import socket
import sys

path, state = sys.argv[1], sys.argv[2]
if os.path.exists(path):
    os.unlink(path)
server = socket.socket(socket.AF_UNIX)
server.bind(path)
os.chmod(path, 0o600)
server.listen(4)
sys.stderr.write("ready\n")
sys.stderr.flush()
while True:
    connection, _ = server.accept()
    connection.recv(4096)
    connection.sendall(('{"ok":true,"state":"%s"}\n' % state).encode())
    connection.close()
