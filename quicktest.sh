#!/usr/bin/env bash
set -e

###############################################################################
# 0. CHECKING DOCKER ON MACOS (IF APPLICABLE)
###############################################################################
OS_TYPE="$(uname -s)"

# If on macOS, verify Docker Desktop is installed & running
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
# PRE-SUPPLIED CREDENTIALS / LICENSE
###############################################################################
UH_REGISTRY_LOGIN="mem_cm6aqbgbz0qnr0tte56bne9aq"
UH_REGISTRY_PASSWORD="G6R9242y4GCo1gRI"
UH_LICENSE_STRING="mem_cm6aqbgbz0qnr0tte56bne9aq:10240:UCR67tj/EnGW1KXtyuU35fQsRrvuOC4bMEwR3uDJ0jk4VTb9qt2LPKTJULhtIfDlA3X6W8Mn/V168/rbIM7eAQ=="
UH_MONITORING_TOKEN="7GcJLtaANgKP8GMX"

###############################################################################
# 1. COLORS & UTILITIES
###############################################################################
BOLD="\033[1m"
BOLD_TEAL="\033[1m\033[38;5;79m"
RESET="\033[0m"

trim_trailing_spaces() {
  echo -e "$1" | sed -E 's/[[:space:]]+$//'
}

###############################################################################
# 2. CHECK PYTHON & CREATE VIRTUAL ENV
###############################################################################
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
echo "Setting up local Python environment..."
PYENV_DIR="$HOME/ultihash-test/.uh_venv"

# Create a local virtual environment if not present
if [[ ! -d "$PYENV_DIR" ]]; then
  python3 -m venv "$PYENV_DIR" >>"$LOG_FILE" 2>&1
fi

# Activate the venv
# shellcheck source=/dev/null
source "$PYENV_DIR/bin/activate"

# Install packages (boto3, tqdm) locally, no sudo required
pip install --quiet --upgrade pip boto3 tqdm >>"$LOG_FILE" 2>&1
echo "✅ Virtual environment ready with boto3 and tqdm installed."

###############################################################################
# 3. SPINNING UP ULTIHASH
###############################################################################
echo ""
echo "Spinning up UltiHash..."

ULTIHASH_DIR="$HOME/ultihash-test"
mkdir -p "$ULTIHASH_DIR"
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
      UH_LOG_LEVEL: INFO
      UH_MONITORING_TOKEN: ${UH_MONITORING_TOKEN}
    command: ["/usr/bin/bash", "-l", "-c", "sleep 10 && uh-cluster --registry etcd:2379 storage"]

  deduplicator:
    image: registry.ultihash.io/stable/core:1.1.1
    depends_on:
      - etcd
      - storage
    environment:
      UH_LICENSE: ${UH_LICENSE_STRING}
      UH_LOG_LEVEL: INFO
      UH_MONITORING_TOKEN: ${UH_MONITORING_TOKEN}
    command: ["/usr/bin/bash", "-l", "-c", "sleep 10 && uh-cluster --registry etcd:2379 deduplicator"]

  entrypoint:
    image: registry.ultihash.io/stable/core:1.1.1
    depends_on:
      - etcd
      - storage
      - deduplicator
    environment:
      UH_LICENSE: ${UH_LICENSE_STRING}
      UH_LOG_LEVEL: INFO
      UH_MONITORING_TOKEN: ${UH_MONITORING_TOKEN}
      UH_DB_HOSTPORT: database:5432
      UH_DB_USER: postgres
      UH_DB_PASS: uh
    volumes:
      - ./policies.json:/etc/uh/policies.json
    command: ["/usr/bin/bash", "-l", "-c", "sleep 15 && uh-cluster --registry etcd:2379 entrypoint"]
    ports:
      - "8080:8080"
EOF

# Log in to the registry quietly
echo "$UH_REGISTRY_PASSWORD" | docker login registry.ultihash.io -u "$UH_REGISTRY_LOGIN" --password-stdin >>"$LOG_FILE" 2>&1 || true

export AWS_ACCESS_KEY_ID="TEST-USER"
export AWS_SECRET_ACCESS_KEY="SECRET"
export UH_LICENSE_STRING
export UH_MONITORING_TOKEN

docker compose up -d >>"$LOG_FILE" 2>&1 || true

echo "🚀 UltiHash is running!"

###############################################################################
# 4. WELCOME
###############################################################################
cat <<WELCOME

👋 Hi! Welcome to the UltiHash test installation.

Here you can store real data to test deduplication, as well as read/write performance.

Deduplication can have significantly different results depending on the dataset.
For best results, try datasets likely to contain repeated data.

You can download benchmark datasets at ultihash.io/benchmarks.

WELCOME

###############################################################################
# 5. PYTHON SCRIPTS (using local venv)
###############################################################################
# The following commands rely on python3 from the venv. We assume "python3" is the same
# one from $PYENV_DIR/bin/ (due to 'source' above).

function store_data() {
  local DATAPATH="$1"
  python3 - <<EOF
import sys, os, pathlib, time
import concurrent.futures
import boto3
from tqdm import tqdm

endpoint="http://127.0.0.1:8080"
bucket="test-bucket"

dp="$DATAPATH".rstrip()
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
  python3 - <<EOF
import sys, os, pathlib, time
import concurrent.futures
import boto3
from tqdm import tqdm

endpoint="http://127.0.0.1:8080"
bucket="test-bucket"

dp="$DATAPATH".rstrip()
outp = pathlib.Path(f"{dp}-retrieved")
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
    lf = outp / bucket / k
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

###############################################################################
# 6. SINGLE RUN
###############################################################################
echo ""
echo -ne "${BOLD_TEAL}Paste the path of the directory you want to test:${RESET} "
IFS= read -r RAW_PATH < /dev/tty
echo ""

RAW_PATH="$(trim_trailing_spaces "$RAW_PATH")"
RAW_PATH="$(echo "$RAW_PATH" | sed -E "s|^[[:space:]]*'(.*)'[[:space:]]*\$|\1|")"

if [[ -z "$RAW_PATH" || ! -e "$RAW_PATH" ]]; then
  echo "❌ You must provide a valid path. Exiting."
  docker compose down -v >>"$LOG_FILE" 2>&1 || true
  exit 1
fi

# 1. Store data => capture actual write speed
WRITE_SPEED="$(store_data "$RAW_PATH" | tr -d '\r\n')"
echo ""

# 2. Read data => capture actual read speed
READ_SPEED="$(read_data "$RAW_PATH" | tr -d '\r\n')"

# 3. Gather dedup info => parse out orig/eff/saved/pct
DE_INFO="$(dedup_info)"
ORIG_GB="$(echo "$DE_INFO" | awk '{print $1}')"
EFF_GB="$(echo "$DE_INFO"  | awk '{print $2}')"
SAV_GB="$(echo "$DE_INFO"  | awk '{print $3}')"
PCT="$(echo "$DE_INFO"     | awk '{print $4}')"

# 4. Shut down & wipe
wipe_cluster

# 5. Print final lines with actual stats
echo ""
echo "➡️  WRITE THROUGHPUT: ${WRITE_SPEED} MB/s"
echo "⬅️  READ THROUGHPUT:  ${READ_SPEED} MB/s"
echo ""
echo "📦 ORIGINAL SIZE: ${ORIG_GB} GB"
echo "✨ DEDUPLICATED SIZE: ${EFF_GB} GB"
echo "✅ SAVED WITH ULTIHASH: ${SAV_GB} GB (${PCT}%)"
echo ""
echo "The UltiHash cluster has been shut down, and the data you stored in it has been wiped."
echo "To measure read performance, a copy of the data was placed in ${RAW_PATH}-retrieved."
echo "Make sure to delete it after checking!"
echo ""
echo -e "${BOLD_TEAL}Claim your free 10TB license at ultihash.io/sign-up 🚀${RESET}"
echo ""
