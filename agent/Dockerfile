# Build stage
FROM nimlang/nim:2.0.0 AS build
RUN apt-get update && apt-get install -y build-essential
WORKDIR /app
COPY agent.nimble .
RUN nimble install -y -d
COPY . .
RUN nim c -d:release --opt:size -o:agent_server src/agent_server.nim

# Run stage
FROM ghcr.io/all-hands-ai/openhands:0.9.0

# Install dependencies needed for the Nim binary (compiled on Debian/Ubuntu)
# If the binary was compiled on Debian, it needs glibc.
# For simplicity and reliability, we'll assume a standard Python/Ubuntu environment here
# and use the official OpenHands user if possible, or create ours.
USER root
RUN apt-get update && apt-get install -y libgcc-s1 libstdc++6 docker.io && rm -rf /var/lib/apt/lists/*

# Create agentuser and set up docker group access
RUN useradd -m -u 1000 agentuser && \
    usermod -aG docker agentuser

WORKDIR /app
COPY --from=build /app/agent_server /app/agent_server

# Workspace directory setup
RUN mkdir -p /app/workspace && chown agentuser:agentuser /app/workspace

USER agentuser
ENTRYPOINT []
CMD ["/app/agent_server"]
