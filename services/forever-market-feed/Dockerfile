# ForeverMarket feed server: collector and read API (server.py), one image, the command picks the role.
#
# The base image is pinned by digest; change the tag and the digest together. psycopg comes from
# requirements.lock (exact versions with hashes), regenerated with the command in README.md (section Server).
FROM python:3.12.16-slim-trixie@sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_ROOT_USER_ACTION=ignore

WORKDIR /app

COPY requirements.lock ./
RUN pip install --require-hashes --no-deps -r requirements.lock

COPY feed.py server.py ./

USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["python", "server.py"]
CMD ["serve"]
