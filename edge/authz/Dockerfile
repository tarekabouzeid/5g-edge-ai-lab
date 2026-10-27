# edge-authz: the edge authorization server (docs/security.md). Built into
# minikube's Docker daemon by edge/minikube-up.sh (image edge-authz:local,
# imagePullPolicy: Never — no registry involved).
FROM python:3.12.14-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py admin.py ./
# Non-root; the runtime revocation state lives on an emptyDir at /run/authz.
USER 10001
EXPOSE 8080
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080", "--no-server-header"]
