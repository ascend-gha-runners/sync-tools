FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      jq \
      git \
      ca-certificates \
      curl \
 && rm -rf /var/lib/apt/lists/*

RUN pip config set global.index-url https://mirrors.huaweicloud.com/repository/pypi/simple \
 && pip install --upgrade pip \
 && pip install \
      filelock \
      modelscope \
      datasets \
      huggingface_hub[cli]

WORKDIR /workspace

CMD ["bash"]
