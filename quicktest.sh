#!/usr/bin/env bash

###############################################################################
# 0. TRAP ANY UNEXPECTED ERRORS => Show log file path, then exit.
###############################################################################
set -e
trap 'echo "❌ Something unexpected happened. Please check the log file at $LOG_FILE"; exit 1' ERR

###############################################################################
# 1. CHECK DOCKER ON MAC (IF APPLICABLE)
###############################################################################
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

###############################################################################
# 2. PRE-SUPPLIED CREDENTIALS / LICENSE
###############################################################################
UH_REGISTRY_LOGIN="demo"
UH_REGISTRY_PASSWORD="M_X!DFlE@jf1:Ztl"
UH_LICENSE_STRING="mem_cm6aqbgbz0qnr0tte56bne9aq:10240:UCR67tj/EnGW1KXtyuU35fQsRrvuOC4bMEwR3uDJ0jk4VTb9qt2LPKTJULhtIfDlA3X6W8Mn/V168/rbIM7eAQ=="
UH_MONITORING_TOKEN="mQRQeeYoGVXHNE0i"
UH_CLUSTER_ID=$(uuidgen)

###############################################################################
# 3. COLORS & UTILITIES
###############################################################################
BOLD="\033[1m"
BOLD_TEAL="\033[1m\033[38;5;79m"
RESET="\033[0m"

trim_trailing_spaces() {
  echo -e "$1" | sed -E 's/[[:space:]]+$//'
}

###############################################################################
# 4. CHECK PYTHON & CREATE VIRTUAL ENV (NO SUDO)
###############################################################################
if ! command -v python3 &>/dev/null; then
  echo "❌ Python 3 is not installed (python3 not found in PATH)."
  echo "Please install Python 3.6 or higher, then re-run."
  exit 1
fi

# Keep logs in a known location
LOG_DIR="$HOME/ultihash-test"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/install-silent.log"
touch "$LOG_FILE"

echo ""
echo "Setting up local Python environment (no sudo required)..."
PYENV_DIR="$HOME/ultihash-test/.uh_venv"

# Create a local virtual environment if not present
if [[ ! -d "$PYENV_DIR" ]]; then
  python3 -m venv "$PYENV_DIR" >>"$LOG_FILE" 2>&1
fi

# Activate the venv
# shellcheck source=/dev/null
source "$PYENV_DIR/bin/activate"

# Install packages in venv => no system-wide changes
pip install --quiet --upgrade pip boto3 tqdm >>"$LOG_FILE" 2>&1
echo "✅ Virtual environment ready with boto3 and tqdm installed."

###############################################################################
# 5. SPINNING UP ULTIHASH
###############################################################################
echo ""
echo "Spinning up UltiHash..."

ULTIHASH_DIR="$HOME/ultihash-test"  # We'll remove this directory at the end if all goes well.
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
    image: registry.ultihash.io/stable/database-init:1.1.1
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

  storage:
    image: registry.ultihash.io/stable/core:1.1.1
    depends_on:
      - etcd
    environment:
      UH_LICENSE: ${UH_LICENSE_STRING}
      UH_LOG_LEVEL: WARN
      UH_OTEL_ENDPOINT: http://collector:4317
      UH_OTEL_INTERVAL: 1000
    command: ["/usr/bin/bash", "-l", "-c", "sleep 10 && uh-cluster --registry etcd:2379 storage"]

  deduplicator:
    image: registry.ultihash.io/stable/core:1.1.1
    depends_on:
      - etcd
      - storage
    environment:
      UH_LICENSE: ${UH_LICENSE_STRING}
      UH_LOG_LEVEL: WARN
      UH_OTEL_ENDPOINT: http://collector:4317
      UH_OTEL_INTERVAL: 1000
    command: ["/usr/bin/bash", "-l", "-c", "sleep 10 && uh-cluster --registry etcd:2379 deduplicator"]

  entrypoint:
    image: registry.ultihash.io/stable/core:1.1.1
    depends_on:
      - etcd
      - storage
      - deduplicator
    environment:
      UH_LICENSE: ${UH_LICENSE_STRING}
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

# Log in to the registry quietly
echo "$UH_REGISTRY_PASSWORD" | docker login registry.ultihash.io -u "$UH_REGISTRY_LOGIN" --password-stdin >>"$LOG_FILE" 2>&1 || true

export AWS_ACCESS_KEY_ID="TEST-USER"
export AWS_SECRET_ACCESS_KEY="SECRET"
export UH_LICENSE_STRING
export UH_MONITORING_TOKEN

docker compose up -d >>"$LOG_FILE" 2>&1 || true

echo "Waiting for UltiHash cluster to fully start..."

# Implement a spinner for better UX
function spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf "🔄 Waiting for UltiHash to become healthy... [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\r"
    done
}

# Start health check in background
(
    MAX_WAIT=60  # Maximum wait time in seconds
    WAIT_INTERVAL=2
    elapsed=0

    while true; do
        if docker compose exec -T entrypoint curl -s http://localhost:8080/health | grep '"status":"healthy"' &>/dev/null; then
            echo "🚀 UltiHash is running!"
            exit 0
        else
            if [[ $elapsed -ge $MAX_WAIT ]]; then
                echo "❌ UltiHash failed to start within $MAX_WAIT seconds."
                exit 1
            fi
            sleep $WAIT_INTERVAL
            elapsed=$((elapsed + WAIT_INTERVAL))
        fi
    done
) &

health_pid=$!

# Start spinner
spinner $health_pid &

spinner_pid=$!

# Wait for health check to complete
wait $health_pid
health_status=$?

# Stop spinner
kill $spinner_pid 2>/dev/null || true
wait $spinner_pid 2>/dev/null || true

if [[ $health_status -ne 0 ]]; then
    exit 1
fi

###############################################################################
# 6. WELCOME
###############################################################################
cat <<WELCOME

👋 Hi! Welcome to the UltiHash test installation.

Here you can store real data to test deduplication, as well as read/write performance.

Deduplication can have significantly different results depending on the dataset.
For best results, try datasets likely to contain repeated data.

You can download benchmark datasets at ultihash.io/benchmarks.

WELCOME

###############################################################################
# 7. PYTHON SCRIPTS (store, read, dedup, verify)
###############################################################################
# We'll place the read copy in $ULTIHASH_DIR/retrieved instead of next to original.

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
  local READ_OUT_DIR="$ULTIHASH_DIR/retrieved"  # Put retrieved data here
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
    lf = outp / k  # same structure, but in retrieved folder
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

###############################################################################
# 7.5 CHECKSUM VALIDATION (REPLACED PYTHON WITH MD5SUM)
###############################################################################
function compare_checksums() {
  local ORIGINAL_PATH="$1"
  local RETRIEVED_DIR="$ULTIHASH_DIR/retrieved"

  local tmp_orig="/tmp/original.md5"
  local tmp_retr="/tmp/retrieved.md5"
  local tmp_diff="/tmp/compare_diff.txt"
  rm -f "$tmp_orig" "$tmp_retr" "$tmp_diff"

  echo "📁 Computing MD5 checksums..."

  if [[ -d "$ORIGINAL_PATH" ]]; then
    echo "🔄 Processing directory: $ORIGINAL_PATH"
    (cd "$ORIGINAL_PATH" && find . -type f -exec md5sum {} + | sort -k 2) > "$tmp_orig"
    (cd "$RETRIEVED_DIR" && find . -type f -exec md5sum {} + | sort -k 2) > "$tmp_retr"
  else
    echo "🔄 Processing file: $ORIGINAL_PATH"
    local fbase
    fbase="$(basename "$ORIGINAL_PATH")"
    md5sum "$ORIGINAL_PATH" | sed "s|$ORIGINAL_PATH|./$fbase|" > "$tmp_orig"
    md5sum "$RETRIEVED_DIR/$fbase" | sed "s|$RETRIEVED_DIR/$fbase|./$fbase|" > "$tmp_retr"
  fi

  echo "🔍 Comparing checksums..."
  diff -u "$tmp_orig" "$tmp_retr" > "$tmp_diff" || true

  if [[ -s "$tmp_diff" ]]; then
    echo "❌ MD5 CHECKSUM MISMATCHES found. See $tmp_diff for details."
  else
    echo "✅ All file checksums match!"
  fi
}

###############################################################################
# 8. ADDITIONAL PYTHON FUNCTION => DEDUP INFO
###############################################################################
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

###############################################################################
# 9. MAIN LOOP => PROMPT FOR VALID PATH
###############################################################################
while true; do
  echo ""
  echo -ne "${BOLD_TEAL}Paste the path of the directory you want to test:${RESET} "
  IFS= read -r RAW_PATH < /dev/tty
  echo ""

  RAW_PATH="$(trim_trailing_spaces "$RAW_PATH")"
  # Expand ~ in the path
  RAW_PATH="$(eval echo "$RAW_PATH")"

  if [[ -z "$RAW_PATH" || ! -e "$RAW_PATH" ]]; then
    echo "❌ Path '$RAW_PATH' is not valid. Please try again."
    continue
  else
    break
  fi
done

# 1. Store data => capture actual write speed
echo "📤 Storing data..."
WRITE_SPEED="$(store_data "$RAW_PATH" | tr -d '\r\n')"
echo ""

# 2. Read data => capture actual read speed
echo "📥 Reading data..."
READ_SPEED="$(read_data "$RAW_PATH" | tr -d '\r\n')"
echo ""

# 3. Compare checksums => store a summary
echo "🔍 Comparing checksums..."
compare_checksums "$RAW_PATH"
CS_RESULT="Check completed."

# 4. Gather dedup info => parse out orig/eff/saved/pct
echo "📊 Gathering deduplication info..."
DE_INFO="$(dedup_info)"
ORIG_GB="$(echo "$DE_INFO" | awk '{print $1}')"
EFF_GB="$(echo "$DE_INFO"  | awk '{print $2}')"
SAV_GB="$(echo "$DE_INFO"  | awk '{print $3}')"
PCT="$(echo "$DE_INFO"     | awk '{print $4}')"

# 5. Shut down & wipe (Run in background)
echo "🧹 Cleaning up..."
wipe_cluster &
CLEANUP_PID=$!

# 6. Wait for cleanup to finish with a spinner
function cleanup_spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf "🧹 Cleaning up... [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\r"
    done
}

cleanup_spinner $CLEANUP_PID &

spinner_pid=$!

# Wait for cleanup to complete
wait $CLEANUP_PID
cleanup_status=$?

# Stop spinner
kill $spinner_pid 2>/dev/null || true
wait $spinner_pid 2>/dev/null || true

if [[ $cleanup_status -ne 0 ]]; then
    echo "❌ Cleanup encountered issues. Please check the log file."
else
    echo "✅ Cleanup completed successfully."
fi

# 7. Delete the entire ultihash-test folder if everything proceeded normally
rm -rf "$ULTIHASH_DIR"

# 8. Print final lines with actual stats
echo ""
echo "➡️  WRITE THROUGHPUT: ${WRITE_SPEED} MB/s"
echo "⬅️  READ THROUGHPUT:  ${READ_SPEED} MB/s"
echo ""
echo "🔎 CHECKSUM RESULTS: ${CS_RESULT}"
echo ""
echo "📦 ORIGINAL SIZE: ${ORIG_GB} GB"
echo "✨ DEDUPLICATED SIZE: ${EFF_GB} GB"
echo "✅ SAVED WITH ULTIHASH: ${SAV_GB} GB (${PCT}%)"
echo ""
echo "The UltiHash cluster has been shut down, and the data you stored in it has been wiped."
echo "Your read copy (for verifying correctness) was placed in an internal folder, which we've also removed now."
echo ""
echo -e "${BOLD_TEAL}Claim your free 10TB license at ultihash.io/sign-up 🚀${RESET}"
echo ""
