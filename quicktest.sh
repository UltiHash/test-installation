#!/usr/bin/env bash

set -e
trap 'echo "❌ Something unexpected happened. Please check the log file at $LOG_FILE"; exit 1' ERR

# If a positional parameter is provided, use it as the cluster ID.
# Otherwise, generate a random UUID.
if [[ -n "$1" ]]; then
    UH_CLUSTER_ID="$1"
else
    UH_CLUSTER_ID=$(uuidgen)
fi

# Spinner Function
show_spinner() {
    local pid=$1
    local message=$2
    local spinstr='|/-\'
    local delay=0.1
    local spin_index=0

    while kill -0 "$pid" 2>/dev/null; do
        printf "\r%s %c" "$message" "${spinstr:spin_index:1}"
        spin_index=$(( (spin_index + 1) % 4 ))
        sleep "$delay"
    done
    printf "\r%s ✅" "$message"
}

OS_TYPE="$(uname -s)"

if [[ "$OS_TYPE" == "Darwin"* ]]; then
    if ! command -v docker &>/dev/null; then
        echo "❌ Docker is not installed on this Mac!"
        echo ""
        echo "➡️  Download and install Docker Desktop from:"
        echo "    https://www.docker.com/products/docker-desktop/"
        exit 1
    fi

    if ! docker info &>/dev/null; then
        echo "❌ Docker Desktop is not running!"
        echo ""
        echo "Please open Docker Desktop, wait for it to start,"
        echo "then press Enter to continue..."
        read -r < /dev/tty
        if ! docker info &>/dev/null; then
            echo ""
            echo "❌ Docker Desktop is still not running. Exiting."
            exit 1
        fi
    fi
fi

UH_REGISTRY_LOGIN="demo"
UH_REGISTRY_PASSWORD="M_X!DFlE@jf1:Ztl"
UH_LICENSE_STRING='{"version":"v1","customer_id":"demo","license_type":"freemium","storage_cap_gib":1024,"signature":"p3HKoEvyQKV72KMN7kP29xa3/pA/XX/K+uXn8P5ub2R5gvrFidEKYkIqKti1M8xbS/6ZRdISzCeSG8tJoff1Dg=="}'
UH_MONITORING_TOKEN="mQRQeeYoGVXHNE0i"

BOLD="\033[1m"
BOLD_TEAL="\033[1m\033[38;5;79m"
RESET="\033[0m"

trim_trailing_spaces() {
  echo -e "$1" | sed -E 's/[[:space:]]+$//'
}

if ! command -v python3 &>/dev/null; then
  echo "❌ Python 3 is not installed (python3 not found in PATH)."
  echo "Please install Python 3.6 or higher, then re-run."
  exit 1
fi

LOG_DIR="$HOME/ultihash-test"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/install-silent.log"
touch "$LOG_FILE"

echo ""
show_spinner "$spin_pid" "Setting up local Python environment for this test..."
PYENV_DIR="$HOME/ultihash-test/.uh_venv"

if [[ ! -d "$PYENV_DIR" ]]; then
  python3 -m venv "$PYENV_DIR" >>"$LOG_FILE" 2>&1
fi

source "$PYENV_DIR/bin/activate"

pip install --quiet --upgrade pip boto3 tqdm >>"$LOG_FILE" 2>&1

echo ""

ULTIHASH_DIR="$HOME/ultihash-test"
cd "$ULTIHASH_DIR"

cat <<EOF > policies.json
{
    "Version": "2012-10-17",
    "Statement": {
        "Sid":  "AllowAllForAnybody",
        "Effect": "Allow",
        "Action": "*",
        "Principal": "*",
        "Resource": "*"
    }
}
EOF

cat <<EOF > collector.yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: '0.0.0.0:4317'
      http:

processors:
  batch:
    send_batch_size: 50
    timeout: 2s  
  attributes/metrics:
    actions:
     - key: ultihash_cluster_id
       action: insert
       value: "${UH_CLUSTER_ID}"

exporters:
  debug: {}
  otlphttp/uptrace:
    endpoint: https://collector.ultihash.io
    headers: { 'uptrace-dsn': https://${UH_MONITORING_TOKEN}@collector.ultihash.io }

service:
  pipelines:
    metrics:
      receivers: [otlp]
      processors: [attributes/metrics, batch]
      exporters: [otlphttp/uptrace, debug]
    logs:
      receivers: [otlp]
      exporters: [debug]
EOF

cat <<EOF > compose.yml
services:
  database:
    image: bitnami/postgresql:16.3.0
    environment:
      POSTGRESQL_PASSWORD: uh
    healthcheck:
      test: [ "CMD-SHELL", "pg_isready -U postgres" ]
      interval: 5s
      timeout: 5s
      retries: 5

  etcd:
    image: bitnami/etcd:3.5.12
    environment:
      ALLOW_NONE_AUTHENTICATION: yes

  database-init:
    image: registry.ultihash.io/stable/database-init:1.3.0
    depends_on:
      - database
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: uh
      SUPER_USER_USERNAME: root
      SUPER_USER_ACCESS_KEY_ID: TEST-USER
      SUPER_USER_SECRET_KEY: SECRET
      DB_USER: postgres
      DB_HOST: database
      DB_PORT: 5432
      PGPASSWORD: uh

  coordinator:
    image: registry.ultihash.io/stable/core:1.3.0
    depends_on:
       - etcd
    environment:
      UH_BACKEND_HOST: 6jdzxvbv3g.execute-api.eu-central-1.amazonaws.com
      UH_LICENSE: ${UH_LICENSE_STRING}
      UH_LOG_LEVEL: INFO
      UH_DB_USER: postgres
      UH_DB_HOSTPORT: database:5432
      UH_DB_PASS: uh
    command: ["/usr/bin/bash", "-l", "-c", "sleep 10 && uh-cluster --registry etcd:2379 coordinator"]

  storage:
    image: registry.ultihash.io/stable/core:1.3.0
    depends_on:
      - etcd
    environment:
      UH_LOG_LEVEL: WARN
      UH_OTEL_ENDPOINT: http://collector:4317
      UH_OTEL_INTERVAL: 1000
    command: ["/usr/bin/bash", "-l", "-c", "sleep 10 && uh-cluster --registry etcd:2379 storage"]

  deduplicator:
    image: registry.ultihash.io/stable/core:1.3.0
    depends_on:
      - etcd
      - storage
    environment:
      UH_LOG_LEVEL: WARN
      UH_OTEL_ENDPOINT: http://collector:4317
      UH_OTEL_INTERVAL: 1000
    command: ["/usr/bin/bash", "-l", "-c", "sleep 10 && uh-cluster --registry etcd:2379 deduplicator"]

  entrypoint:
    image: registry.ultihash.io/stable/core:1.3.0
    depends_on:
      - etcd
      - storage
      - deduplicator
    environment:
      UH_LOG_LEVEL: WARN
      UH_DB_HOSTPORT: database:5432
      UH_DB_USER: postgres
      UH_DB_PASS: uh
      UH_OTEL_ENDPOINT: http://collector:4317
      UH_OTEL_INTERVAL: 1000
    volumes:
      - ./policies.json:/etc/uh/policies.json
    command: ["/usr/bin/bash", "-l", "-c", "sleep 15 && uh-cluster --registry etcd:2379 entrypoint"]
    ports:
      - "8080:8080"

  collector:
    image: otel/opentelemetry-collector-contrib:0.118.0
    volumes:
      - ./collector.yaml:/etc/otelcol-contrib/config.yaml
EOF

echo "$UH_REGISTRY_PASSWORD" | docker login registry.ultihash.io -u "$UH_REGISTRY_LOGIN" --password-stdin >>"$LOG_FILE" 2>&1 || true

export AWS_ACCESS_KEY_ID="TEST-USER"
export AWS_SECRET_ACCESS_KEY="SECRET"
export UH_LICENSE_STRING
export UH_MONITORING_TOKEN

docker compose up -d >>"$LOG_FILE" 2>&1 || true

sleep 15 &
spin_pid=$!
show_spinner "$spin_pid" "Spinning up UltiHash cluster with Docker..."

echo " "

cat <<WELCOME

👋 Hi! Welcome to the UltiHash test installation.

Here you can store real data to test deduplication, as well as read/write performance.

Deduplication can have significantly different results depending on the dataset.
For best results, try datasets likely to contain repeated data.

You can download benchmark datasets at ultihash.io/benchmarks.

WELCOME

function store_data() {
  local DATAPATH="$1"
  python3 - <<EOF
import sys, os, pathlib, time
import concurrent.futures
import boto3
from tqdm import tqdm

endpoint = "http://127.0.0.1:8080"
bucket = "test-bucket"

dp = "$DATAPATH".rstrip()
pp = pathlib.Path(dp)

s3 = boto3.client("s3", endpoint_url=endpoint)

try:
    s3.create_bucket(Bucket=bucket)
except:
    pass

def gather_files(basep):
    if basep.is_file():
        return [(basep, basep.parent)], basep.stat().st_size
    st = 0
    fl = []
    for (root, dirs, files) in os.walk(basep):
        for f in files:
            fu = pathlib.Path(root)/f
            st += fu.stat().st_size
            fl.append((fu, basep))
    return fl, st

files_list, total_sz = gather_files(pp)
start = time.time()

progress = tqdm(
    total=total_sz,
    desc="Deduplicating + writing",
    unit="B",
    unit_scale=True,
    unit_divisor=1024
)
pool = concurrent.futures.ThreadPoolExecutor(max_workers=8)

def do_store(fp, base):
    def cb(x):
        progress.update(x)
        progress.refresh()
    k = str(fp.relative_to(base))
    s3.upload_file(str(fp), bucket, k, Callback=cb)

futs = []
for (fp, bs) in files_list:
    futs.append(pool.submit(do_store, fp, bs))
for ft in futs:
    ft.result()

progress.close()
elapsed = time.time() - start
mb = total_sz / (1024 * 1024)
speed = 0
if elapsed > 0:
    speed = mb / elapsed

print(f"{speed:.2f}")
EOF
}

function read_data() {
  local DATAPATH="$1"
  local READ_OUT_DIR="$ULTIHASH_DIR/retrieved"
  python3 - <<EOF
import sys, os, pathlib, time
import concurrent.futures
import boto3
from tqdm import tqdm

endpoint = "http://127.0.0.1:8080"
bucket = "test-bucket"

dp = "$DATAPATH".rstrip()
outp = pathlib.Path("$READ_OUT_DIR")
outp.mkdir(parents=True, exist_ok=True)

s3 = boto3.client("s3", endpoint_url=endpoint)

def gather_keys_and_size():
    total_s = 0
    allk = []
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket):
        for obj in page.get("Contents", []):
            allk.append(obj["Key"])
            total_s += obj["Size"]
    return allk, total_s

keys, total_sz = gather_keys_and_size()

start = time.time()

progress = tqdm(
    total=total_sz,
    desc="Reconstructing + reading",
    unit="B",
    unit_scale=True,
    unit_divisor=1024
)

def download_object(k):
    resp = s3.get_object(Bucket=bucket, Key=k)
    body = resp["Body"]
    lf = outp / k
    lf.parent.mkdir(parents=True, exist_ok=True)
    while True:
        chunk = body.read(128 * 1024)
        if not chunk:
            break
        with open(lf, "ab") as f:
            f.write(chunk)
        progress.update(len(chunk))
        progress.refresh()

pool = concurrent.futures.ThreadPoolExecutor(max_workers=8)
farr = []
for kk in keys:
    farr.append(pool.submit(download_object, kk))
for ft in farr:
    ft.result()

progress.close()
elapsed = time.time() - start
mb = total_sz / (1024 * 1024)
speed = 0
if elapsed > 0:
    speed = mb / elapsed

print(f"{speed:.2f}")
EOF
}

function dedup_info() {
  python3 - <<EOF
import sys, json
import boto3

s3 = boto3.client("s3", endpoint_url="http://127.0.0.1:8080")
resp = s3.get_object(Bucket="ultihash", Key="v1/metrics/cluster")
data = json.loads(resp["Body"].read())

orig = data.get("raw_data_size", 0)
eff  = data.get("effective_data_size", 0)
sav  = orig - eff
pct  = 0
if orig > 0:
    pct = (sav / orig) * 100
print(f"{orig/1e9:.2f} {eff/1e9:.2f} {sav/1e9:.2f} {pct:.2f}")
EOF
}

function wipe_cluster() {
  docker compose down -v >>"$LOG_FILE" 2>&1 || true
  python3 - <<EOF
import sys, boto3

endpoint="http://127.0.0.1:8080"
b="test-bucket"
s3 = boto3.client("s3", endpoint_url=endpoint)
try:
    content = s3.list_objects_v2(Bucket=b).get("Contents",[])
    for obj in content:
        s3.delete_object(Bucket=b, Key=obj["Key"])
    s3.delete_bucket(Bucket=b)
except:
    pass
EOF
}

while true; do
  echo -ne "${BOLD_TEAL}Paste the path of the directory you want to test:${RESET} "
  IFS= read -r RAW_PATH < /dev/tty
  echo ""

  RAW_PATH="$(trim_trailing_spaces "$RAW_PATH")"
  RAW_PATH="$(eval echo "$RAW_PATH")"

  if [[ -z "$RAW_PATH" || ! -e "$RAW_PATH" ]]; then
    echo "❌ Path '$RAW_PATH' is not valid. Please try again."
    continue
  else
    break
  fi
done

WRITE_SPEED="$(store_data "$RAW_PATH" | tr -d '\r\n')"
echo ""

READ_SPEED="$(read_data "$RAW_PATH" | tr -d '\r\n')"
echo ""

DE_INFO="$(dedup_info)"
ORIG_GB="$(echo "$DE_INFO" | awk '{print $1}')"
EFF_GB="$(echo "$DE_INFO"  | awk '{print $2}')"
SAV_GB="$(echo "$DE_INFO"  | awk '{print $3}')"
PCT="$(echo "$DE_INFO"     | awk '{print $4}')"

wipe_cluster &
spin_pid=$!
show_spinner "$spin_pid" "Generating stats and shutting down cluster..."

echo " "
echo ""
echo "➡️  WRITE THROUGHPUT: ${WRITE_SPEED} MB/s"
echo "⬅️  READ THROUGHPUT:  ${READ_SPEED} MB/s"
echo ""
echo "📦 ORIGINAL SIZE: ${ORIG_GB} GB"
echo "✨ DEDUPLICATED SIZE: ${EFF_GB} GB"
echo "✅ SAVED WITH ULTIHASH: ${SAV_GB} GB (${PCT}%)"
echo ""
echo "The cluster has been shut down, and the data you stored in it has been wiped. (Your original data remains.)"
echo "The retrieved copy of the dataset is available in the same directory."
echo ""
echo -e "${BOLD_TEAL}Claim your free 10TB license at ultihash.io/sign-up 🚀${RESET}"
echo ""
