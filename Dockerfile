FROM python:3.12-slim

WORKDIR /app

COPY app/requirements.txt .

RUN pip install --no-cache-dir -r app/requirements.txt

COPY app/ .

RUN useradd -m appuser
USER appuser

EXPOSE 8080

CMD ["python", "app.py"]
