# /opt/uisp-test/Dockerfile
FROM ubuntu:24.04

# Install tools and Python
RUN apt-get update && apt-get install -y wget \
    curl \
    jq \
    bash \
    cron \
    postgresql-client \
    dnsutils \
    net-tools \
    iputils-ping \
    openssl \
    ca-certificates \
    tzdata \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Install Python libraries for polling script
RUN apt-get update && apt-get install -y python3-psycopg2 python3-pandas inotify-tools && rm -rf /var/lib/apt/lists/*

# Install Python packages via pip
RUN pip3 install bcrypt fastapi uvicorn[standard] --break-system-packages

# Timezone
ENV TZ=America/New_York
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Dirs
RUN mkdir -p /app /container-data /container-data/logs

# Copy files
COPY . /app/

# Scripts executable
RUN chmod +x /app/*.sh 2>/dev/null || true

WORKDIR /app

# MOTD
RUN echo '# uisp-tester ready!' > /etc/motd && \
    echo '# psql, curl, jq, dig, ping' >> /etc/motd && \
    echo '# Data: /container-data' >> /etc/motd

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["sleep", "infinity"]