#!/bin/sh
# Usage: VLYRA_SSH="-i ~/.ssh/key deploy@host" deploy/deploy.sh
set -eu
cd "$(dirname "$0")/.."
: "${VLYRA_SSH:?set VLYRA_SSH, e.g. VLYRA_SSH=\"-i ~/.ssh/key deploy@host\"}"

# shellcheck disable=SC2086
case "$(ssh $VLYRA_SSH uname -m)" in
  aarch64 | arm64) platform=linux/arm64 ;;
  x86_64) platform=linux/amd64 ;;
  *) echo "unsupported server CPU" >&2; exit 1 ;;
esac

docker build --platform "$platform" -f deploy/Dockerfile --target build -t vlyra-build .
docker run --rm --platform "$platform" -v "$PWD/deploy:/out" vlyra-build cp /src/vlyra /out/vlyra-linux

# shellcheck disable=SC2086
COPYFILE_DISABLE=1 tar czf - --no-xattrs .dockerignore deploy/Dockerfile deploy/compose.yaml deploy/vlyra-linux \
  | ssh $VLYRA_SSH 'mkdir -p ~/vlyra && cd ~/vlyra && tar xzf - && cd deploy && docker compose up -d --build'
