# ForeverMarket feed server: collector and read API (server.py), one image, the command picks the role
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN pip install --no-cache-dir "psycopg[binary]==3.3.9" \
    && useradd --system --uid 10001 --home /app feed
WORKDIR /app
COPY feed.py server.py ./
USER feed
EXPOSE 8080
ENTRYPOINT ["python", "server.py"]
CMD ["serve"]
