# Build stage
FROM nimlang/nim:alpine-regular AS build
RUN apk add --no-cache build-base
WORKDIR /app
COPY agent.nimble .
RUN nimble install -y -d
COPY . .
RUN nim c -d:release --opt:size -o:agent_server src/agent_server.nim

# Run stage
FROM docker.openhands.dev/openhands/openhands:0.9

# Install dependencies needed for the Nim binary (compiled on Alpine/musl)
# If the binary was compiled on Alpine, it might need musl fixes on Ubuntu.
# For simplicity and reliability, we'll assume a standard Python/Ubuntu environment here
# and use the official OpenHands user if possible, or create ours.
USER root
RUN apt-get update && apt-get install -y libgcc-s1 libstdc++6 shadow docker.io && rm -rf /var/lib/apt/lists/*

# Create agentuser and set up docker group access
RUN useradd -m -u 1000 agentuser && \
    usermod -aG docker agentuser

WORKDIR /app
COPY --from=build /app/agent_server /app/agent_server

# Workspace directory setup
RUN mkdir -p /app/workspace && chown agentuser:agentuser /app/workspace

USER agentuser
CMD ["/app/agent_server"]
