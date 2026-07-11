ARG RUBY_VERSION
FROM ruby:${RUBY_VERSION}-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential git libpq-dev postgresql-client \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 audit \
    && useradd --uid 10001 --gid audit --create-home audit \
    && mkdir -p /opt/rails-audit /workspace \
    && chown audit:audit /workspace

COPY boot.rb /opt/rails-audit/boot.rb

USER audit
WORKDIR /workspace
