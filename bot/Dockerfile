# Build stage
FROM nimlang/nim:alpine AS build
RUN apk add --no-cache openssl-dev build-base
WORKDIR /app
COPY bot.nimble .
RUN nimble install -y -d
COPY . .
RUN nim c -d:release -d:ssl --opt:size -o:bot src/bot.nim

# Run stage
FROM alpine:latest
RUN apk add --no-cache openssl ca-certificates libgcc libstdc++ pcre
WORKDIR /app
COPY --from=build /app/bot /app/bot
CMD ["/app/bot"]
