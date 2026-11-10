#!/bin/sh
# Keep this terminal open beside `wrangler dev`; Ctrl-C removes only our state.
set -eu
umask 077
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
vars="$root/worker/.dev.vars"
if [ -e "$vars" ] || [ -L "$vars" ]; then
  printf '%s\n' "Refusing to overwrite $vars. Keep your configured S3 backend, or move that file aside first." >&2
  exit 1
fi
for command in curl openssl node; do
  command -v "$command" >/dev/null || { printf 'Install %s first.\n' "$command" >&2; exit 1; }
done
if [ ! -d "$root/worker/node_modules/aws4fetch" ]; then
  printf '%s\n' 'Run (cd worker && npm ci) first.' >&2
  exit 1
fi
case "$(uname -s)/$(uname -m)" in
  Linux/x86_64) target=x86_64-unknown-linux-musl ;;
  Linux/aarch64) target=aarch64-unknown-linux-musl ;;
  *) printf '%s\n' 'This Garage helper supports Linux x86_64/aarch64.' >&2; exit 1 ;;
esac
port=${GARAGE_PORT:-14900}
case "$port" in *[!0-9]*|'') printf '%s\n' 'GARAGE_PORT must be a port number.' >&2; exit 1 ;; esac
if [ "$port" -lt 1024 ] || [ "$port" -gt 65532 ]; then
  printf '%s\n' 'GARAGE_PORT must be between 1024 and 65532.' >&2
  exit 1
fi
rpc_port=$((port + 1))
web_port=$((port + 2))
cache="$root/.dart_tool/garage"
mkdir -p "$cache"
binary="$cache/garage-v2.5.0-$target"
if [ ! -f "$binary" ]; then
  curl --fail --location --remove-on-error "https://garagehq.deuxfleurs.fr/_releases/v2.5.0/$target/garage" -o "$binary.part.$$"
  chmod 700 "$binary.part.$$"
  mv "$binary.part.$$" "$binary"
fi
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/flasher-garage.XXXXXX")
garage_pid=
own_vars=0
cleanup() {
  if [ -n "$garage_pid" ]; then
    kill "$garage_pid" 2>/dev/null || true
    wait "$garage_pid" 2>/dev/null || true
  fi
  # Never remove edits made by the user while this helper was running.
  if [ "$own_vars" = 1 ] && cmp -s "$vars" "$work_dir/dev.vars"; then rm -- "$vars"; fi
  rm -rf -- "$work_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export GARAGE_CONFIG_FILE="$work_dir/garage.toml"
export GARAGE_DEFAULT_ACCESS_KEY="GK$(openssl rand -hex 16)"
export GARAGE_DEFAULT_SECRET_KEY="$(openssl rand -hex 32)"
export GARAGE_DEFAULT_BUCKET=ota
cat > "$GARAGE_CONFIG_FILE" <<EOF
metadata_dir = "$work_dir/meta"
data_dir = "$work_dir/data"
db_engine = "sqlite"
replication_factor = 1
rpc_bind_addr = "127.0.0.1:$rpc_port"
rpc_public_addr = "127.0.0.1:$rpc_port"
rpc_secret = "$(openssl rand -hex 32)"
[s3_api]
s3_region = "garage"
api_bind_addr = "127.0.0.1:$port"
root_domain = ".s3.garage.localhost"
[s3_web]
bind_addr = "127.0.0.1:$web_port"
root_domain = ".web.garage.localhost"
index = "index.html"
EOF
"$binary" server --single-node --default-bucket > "$work_dir/garage.log" 2>&1 &
garage_pid=$!
export GARAGE_S3_URL="http://127.0.0.1:$port"
attempt=0
until curl --silent --output /dev/null "$GARAGE_S3_URL/"; do
  if ! kill -0 "$garage_pid" 2>/dev/null || [ "$attempt" -ge 100 ]; then
    cat "$work_dir/garage.log" >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 0.1
done
"$binary" bucket website --allow ota
export FLASHER_ROOT="$root"
node --input-type=module <<'JS'
import { createRequire } from 'node:module';
const require = createRequire(`${process.env.FLASHER_ROOT}/worker/package.json`);
const { AwsClient } = require('aws4fetch');
const signer = new AwsClient({ accessKeyId: process.env.GARAGE_DEFAULT_ACCESS_KEY, secretAccessKey: process.env.GARAGE_DEFAULT_SECRET_KEY, service: 's3', region: 'garage', retries: 0 });
const body = '<CORSConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><CORSRule><AllowedOrigin>*</AllowedOrigin><AllowedMethod>GET</AllowedMethod><AllowedMethod>HEAD</AllowedMethod><AllowedHeader>*</AllowedHeader><ExposeHeader>ETag</ExposeHeader><ExposeHeader>Content-Length</ExposeHeader><ExposeHeader>Content-Range</ExposeHeader><ExposeHeader>x-amz-meta-ota-etag</ExposeHeader><MaxAgeSeconds>86400</MaxAgeSeconds></CORSRule></CORSConfiguration>';
const reply = await signer.fetch(`${process.env.GARAGE_S3_URL}/ota?cors`, { method: 'PUT', body });
if (!reply.ok) throw new Error(`PutBucketCors failed: HTTP ${reply.status}`);
await reply.body?.cancel();
JS
printf 'OTA_S3_ENDPOINT=%s\nOTA_S3_BUCKET=ota\nOTA_S3_REGION=garage\nOTA_PUBLIC_BASE=http://ota.web.garage.localhost:%s/\nOTA_S3_ACCESS_KEY_ID=%s\nOTA_S3_SECRET_ACCESS_KEY=%s\n' \
  "$GARAGE_S3_URL" "$web_port" "$GARAGE_DEFAULT_ACCESS_KEY" "$GARAGE_DEFAULT_SECRET_KEY" > "$work_dir/dev.vars"
(set -C; cat "$work_dir/dev.vars" > "$vars")
own_vars=1
printf '\nGarage ready: http://ota.web.garage.localhost:%s/\nWrote worker/.dev.vars (mode 600). In another terminal: cd worker && npx wrangler dev\nCtrl-C stops this throwaway Garage and removes its unchanged vars/data.\n' "$web_port"
wait "$garage_pid"
