FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-venv python3-pip \
        gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
        make git dtc libelf-dev libssl-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/venv
COPY requirements.txt /tmp/reqs.txt
RUN /opt/venv/bin/pip install --no-cache-dir -r /tmp/reqs.txt

COPY main.py build_module.sh /ko-server/
RUN chmod +x /ko-server/build_module.sh

ENV KO_BASE=/opt/ko \
    KERNEL_SRC=/opt/kern618 \
    SEEED_SRC=/opt/seed-v614 \
    BUILD_SCRIPT=/ko-server/build_module.sh

EXPOSE 8000
CMD ["/opt/venv/bin/uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--app-dir", "/ko-server"]
