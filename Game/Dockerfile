# Headless dedicated server for the Arena game.
# Build:   docker build -t arena-server .
# Run:     docker run --rm -p 27890:27890/udp arena-server

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# The Ubuntu `love` package has a post-install bug (update-alternatives points at a
# man page that the package does not ship), so its postinst exits non-zero even
# though the binary and libraries install correctly. `|| true` tolerates that
# non-fatal failure; the image needs no further apt operations.
RUN apt-get update && \
    (apt-get install -y --no-install-recommends love || true) && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . /app

# Headless LÖVE: disable window/graphics/audio modules (via conf.lua) and give
# SDL a dummy video/audio driver so it never requires a real display or sound card.
ENV GAME_SERVER=1 \
    SDL_VIDEODRIVER=dummy \
    SDL_AUDIODRIVER=dummy

EXPOSE 27890/udp

CMD ["love", ".", "--server"]
