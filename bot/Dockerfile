# Build stage
FROM nimlang/nim:alpine AS build
RUN apk add --no-cache openssl-dev build-base
WORKDIR /app
COPY bot.nimble .
RUN nimble install -y -d
COPY . .
RUN nim c -d:release -d:ssl --opt:size -o:bot src/bot.nim

# Run stage
# Switch to alpine:latest for production reliability while maintaining a lightweight footprint.
# Horiz OS was tested but found to have significant binary execution compatibility issues with custom Nim binaries.
FROM alpine:latest
RUN apk add --no-cache openssl ca-certificates libgcc libstdc++ pcre
WORKDIR /app
COPY --from=build /app/bot /app/bot
CMD ["/app/bot"]
