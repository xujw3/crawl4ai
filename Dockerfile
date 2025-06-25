# Dockerfile

# ==============================================================================
# STAGE 1: Builder - Installs all dependencies and builds the application
# ==============================================================================
FROM python:3.12-slim-bookworm AS builder

# Set Environment Variables
ENV PYTHONFAULTHANDLER=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    DEBIAN_FRONTEND=noninteractive

# Set Build Arguments
ARG APP_HOME=/app
ARG INSTALL_TYPE=default
ARG ENABLE_GPU=false
ARG TARGETARCH

# Install essential build and runtime dependencies via apt
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    wget \
    gnupg \
    git \
    cmake \
    pkg-config \
    python3-dev \
    libjpeg-dev \
    redis-server \
    supervisor \
    # Playwright runtime dependencies
    libglib2.0-0 \
    libnss3 \
    libnspr4 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libcups2 \
    libdrm2 \
    libdbus-1-3 \
    libxcb1 \
    libxkbcommon0 \
    libx11-6 \
    libxcomposite1 \
    libxdamage1 \
    libxext6 \
    libxfixes3 \
    libxrandr2 \
    libgbm1 \
    libasound2 \
    libatspi2.0-0 \
    # Platform-specific optimizations
    && if [ "$TARGETARCH" = "arm64" ]; then apt-get install -y libopenblas-dev; \
       elif [ "$TARGETARCH" = "amd64" ]; then apt-get install -y libomp-dev; fi \
    # Cleanup
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR ${APP_HOME}

# Copy source code and requirements
COPY . .

# Install Python dependencies based on INSTALL_TYPE
# This creates a fully populated virtual environment in /opt/venv
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Install base requirements first
RUN pip install --no-cache-dir -r deploy/docker/requirements.txt

# Install optional dependencies
RUN if [ "$INSTALL_TYPE" = "all" ] ; then \
        pip install --no-cache-dir \
            torch torchvision torchaudio scikit-learn nltk transformers tokenizers && \
        python -m nltk.downloader punkt stopwords ; \
    fi

# Install the crawl4ai package itself with correct extras
RUN if [ "$INSTALL_TYPE" = "all" ] ; then \
        pip install ".[all]" && python -m crawl4ai.model_loader ; \
    elif [ "$INSTALL_TYPE" = "torch" ] ; then \
        pip install ".[torch]" ; \
    elif [ "$INSTALL_TYPE" = "transformer" ] ; then \
        pip install ".[transformer]" && python -m crawl4ai.model_loader ; \
    else \
        pip install . ; \
    fi

# Install playwright browsers
RUN playwright install --with-deps chromium

# Run setup scripts
RUN crawl4ai-setup

# ==============================================================================
# STAGE 2: Final - Creates the lightweight production image
# ==============================================================================
FROM python:3.12-slim-bookworm AS final

# Set Environment Variables
ENV PYTHONFAULTHANDLER=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    DEBIAN_FRONTEND=noninteractive \
    REDIS_HOST=localhost \
    REDIS_PORT=6379 \
    PYTHON_ENV=production

ARG APP_HOME=/app

# Install only RUNTIME dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    redis-server \
    supervisor \
    # Playwright runtime dependencies
    libglib2.0-0 libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
    libdbus-1-3 libxcb1 libxkbcommon0 libx11-6 libxcomposite1 libxdamage1 libxext6 \
    libxfixes3 libxrandr2 libgbm1 libasound2 libatspi2.0-0 \
    # Cleanup
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN groupadd -r appuser && useradd --no-log-init -r -g appuser appuser

WORKDIR ${APP_HOME}

# Copy the virtual environment from the builder
COPY --from=builder /opt/venv /opt/venv

# Copy the Playwright browser cache from the builder to the new user's home
COPY --from=builder /root/.cache/ms-playwright/ /home/appuser/.cache/ms-playwright/

# Copy the entire application code from the builder
COPY --from=builder ${APP_HOME} ${APP_HOME}

# Set correct ownership for all application files and caches
RUN chown -R appuser:appuser ${APP_HOME} \
    && chown -R appuser:appuser /home/appuser/.cache \
    && mkdir -p /var/lib/redis /var/log/redis \
    && chown -R appuser:appuser /var/lib/redis /var/log/redis

# Switch to the non-root user
USER appuser

# Add the venv to the PATH
ENV PATH="/opt/venv/bin:$PATH"

EXPOSE 6379 11235

# Start the application using supervisord, same as the original Dockerfile
CMD ["supervisord", "-c", "deploy/docker/supervisord.conf"]
