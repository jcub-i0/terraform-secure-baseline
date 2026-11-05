FROM docker.io/library/python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN python -m pip install --no-cache-dir -r /app/requirements.txt \
    && python -c "import urllib.request; u='https://truststore.pki.rds.amazonaws.com/us-east-1/us-east-1-bundle.pem'; d=urllib.request.urlopen(u,timeout=20).read(); assert d.count(b'BEGIN CERTIFICATE')>=1; open('/app/rds-ca.pem','wb').write(d)"

COPY app.py /app/app.py
RUN chmod 0444 /app/app.py /app/requirements.txt /app/rds-ca.pem

USER 65534:65534
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD python -c "from urllib.request import urlopen; assert urlopen('http://127.0.0.1:8080/health',timeout=2).status==200"

CMD ["python", "/app/app.py"]
