# Node 22 LTS source stage, copied into the final image below. Pinned to the
# same image/digest as hermes-agent-src/Dockerfile's node_source stage so
# both containers run an identical, already-vetted Node build. Bookworm-based
# slim image links against glibc 2.36, which runs cleanly on this image's
# Debian 13 (trixie, glibc 2.41) base.
FROM node:22-bookworm-slim@sha256:7af03b14a13c8cdd38e45058fd957bf00a72bbe17feac43b1c15a689c029c732 AS node_source

FROM python:3.12-slim

LABEL maintainer="nesquena"
LABEL description="Hermes Web UI — browser interface for Hermes Agent"

# Install system packages
ENV DEBIAN_FRONTEND=noninteractive

# Make use of apt-cacher-ng if available
RUN if [ "A${BUILD_APT_PROXY:-}" != "A" ]; then \
        echo "Using APT proxy: ${BUILD_APT_PROXY}"; \
        printf 'Acquire::http::Proxy "%s";\n' "$BUILD_APT_PROXY" > /etc/apt/apt.conf.d/01proxy; \
    fi \
    && apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates wget gnupg \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

RUN apt-get update -y --fix-missing --no-install-recommends \
    && apt-get install -y --no-install-recommends \
    apt-utils \
    locales \
    ca-certificates \
    curl \
    rsync \
    openssh-client \
    git \
    xz-utils \
    && apt-get upgrade -y \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Optional GPU user-space acceleration libraries for users who pass through
# host GPU devices. The default image remains CPU-only.
ARG INSTALL_GPU_LIBS=0
RUN if [ "$INSTALL_GPU_LIBS" = "1" ]; then \
        apt-get update -y --fix-missing --no-install-recommends \
        && apt-get install -y --no-install-recommends \
            libva2 \
            vainfo \
            mesa-va-drivers \
        && if apt-cache show intel-media-va-driver-non-free >/dev/null 2>&1; then \
            apt-get install -y --no-install-recommends intel-media-va-driver-non-free; \
        else \
            echo "intel-media-va-driver-non-free is not available from the configured Debian repositories; skipping Intel non-free VA-API driver."; \
        fi \
        && apt-get clean \
        && rm -rf /var/lib/apt/lists/*; \
    else \
        echo "Skipping optional GPU user-space acceleration libraries (INSTALL_GPU_LIBS=0)."; \
    fi

# UTF-8
RUN localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8
ENV LANG=en_US.utf8
ENV LC_ALL=C

# Set environment variables
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONIOENCODING=utf-8

WORKDIR /apptoo

# Create the unprivileged runtime user. The entrypoint starts as root only for
# UID/GID alignment and filesystem preparation, then execs the server as this user.
RUN groupadd -g 1024 hermeswebui \
    && useradd -u 1024 -d /home/hermeswebui -g hermeswebui -G users -s /bin/bash -m hermeswebui \
    && mkdir -p /app /uv_cache /workspace \
    && chown -R hermeswebui:hermeswebui /home/hermeswebui /app /uv_cache /workspace \
    && chmod 0755 /home/hermeswebui \
    && chmod 1777 /app /uv_cache /workspace

COPY --chmod=555 docker_init.bash /hermeswebui_init.bash

RUN touch /.within_container

# Remove APT proxy configuration and clean up APT downloaded files
RUN rm -rf /var/lib/apt/lists/* /etc/apt/apt.conf.d/01proxy \
    && apt-get clean

USER root

# Pre-install uv system-wide so the container doesn't need internet access at runtime.
# Installing as root places uv in /usr/local/bin, available to all users.
# The init script will skip the download when uv is already on PATH.
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# Node 22 LTS + npm, copied from the node_source stage above (see that stage
# for the version/digest rationale). npm and npx are recreated as symlinks
# because they're symlinks in the source image.
#
# In the two-container compose setup, browser/run_python/etc. tool calls
# initiated from the WebUI execute inside *this* container, not the agent
# container (hermes-webui's architectural limitation #681 — see
# hermes-webui-src/docs/docker.md). hermes-agent's `browser_*` tools shell
# out to the `agent-browser` npm CLI regardless of CDP-vs-local mode
# (tools/browser_tool.py), so without Node+npm+agent-browser here, every
# WebUI-initiated browser tool call fails with "agent-browser CLI not
# found" even though the agent container has it.
COPY --chmod=0755 --from=node_source /usr/local/bin/node /usr/local/bin/
COPY --from=node_source /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm
RUN ln -sf /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && \
    ln -sf /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

# Pinned to the same version pulled by hermes-agent-src's package.json
# (package-lock.json resolves agent-browser to 0.26.0) so both containers
# drive the browser with identical CLI behavior. `npm install -g` (not
# `npx`) so the binary is baked into the image and no internet access is
# needed at runtime. Only the CLI is installed here, not `agent-browser
# install` — that downloads a local Chromium, which isn't needed since the
# WebUI always connects out to the chromium-playwright sidecar via
# BROWSER_CDP_URL.
RUN npm install -g agent-browser@0.26.0 && npm cache clean --force

COPY --chown=root:root . /apptoo

# Bake the git version tag into the image so the settings badge works even
# when .git is not present (it is excluded by .dockerignore).
# CI passes: --build-arg HERMES_VERSION=$(git describe --tags --always)
# Local builds that omit the arg get "unknown" as the fallback.
ARG HERMES_VERSION=unknown
RUN echo "__version__ = '${HERMES_VERSION}'" > /apptoo/api/_version.py

# Default to binding all interfaces (required for container networking)
ENV HERMES_WEBUI_HOST=0.0.0.0
ENV HERMES_WEBUI_PORT=8787

EXPOSE 8787

HEALTHCHECK --interval=30s --timeout=8s --start-period=10s --retries=3 \
  CMD bash /apptoo/scripts/lib/health_probe.sh localhost 8787 /health 2 >/dev/null || exit 1

# docker_init.bash performs root-only bind-mount setup, then drops to hermeswebui
# before starting the WebUI server. The production image does not ship sudo.
USER root
CMD ["/hermeswebui_init.bash"]

