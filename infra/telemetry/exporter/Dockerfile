# AXIOM fleet-exporter -- stdlib-only Python, no pip install needed.
FROM python:3.12-slim
WORKDIR /app
COPY exporter.py /app/exporter.py
USER 65534:65534
EXPOSE 9100
ENTRYPOINT ["python", "-u", "/app/exporter.py"]
