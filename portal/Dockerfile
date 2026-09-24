FROM python:3.12.14-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
COPY static/ static/
# Host network + 127.0.0.1: reachable from this machine (and the Windows
# browser via WSL2 localhost forwarding), never from the LAN — the portal
# holds the Docker socket.
CMD ["uvicorn", "app:app", "--host", "127.0.0.1", "--port", "8090", "--log-level", "warning"]
