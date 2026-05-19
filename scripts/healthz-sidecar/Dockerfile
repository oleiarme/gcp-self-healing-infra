FROM python:3.12-slim

WORKDIR /opt

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY healthz_server.py .

EXPOSE 8080

CMD ["python3", "healthz_server.py"]
