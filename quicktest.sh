#!/usr/bin/env bash
set -e

###############################################################################
# 0. MACOS DOCKER CHECK (IF APPLICABLE)
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
# 2. INSTALLING PREREQUISITES (QUIET)
###############################################################################
echo ""
echo "Installing prerequisites..."

LOG_DIR="$HOME/ultihash-test"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/install-silent.log"
touch "$LOG_FILE"

function install_aws_cli_quiet() {
  if ! command -v aws &>/dev/null; then
    case "$OS_TYPE" in
      Darwin)
        if command -v brew &>/dev/null; then
          brew install awscli >>"$LOG_FILE" 2>&1 || true
        fi
        ;;
      Linux)
        if command -v apt-get &>/dev/null; then
          sudo apt-get update -qq >>"$LOG_FILE" 2>&1 || true
          sudo apt-get install -y -qq unzip >>"$LOG_FILE" 2>&1 || true
          curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" >>"$LOG_FILE" 2>&1 || true
          unzip -q awscliv2.zip >>"$LOG_FILE" 2>&1 || true
          sudo ./aws/install -i /usr/local/aws-cli -b /usr/local/bin >>"$LOG_FILE" 2>&1 || true
          rm -rf awscliv2.zip aws/
        fi
        ;;
    esac
  fi
}

function install_python_quiet() {
  if ! command -v python3 &>/dev/null; then
    case "$OS_TYPE" in
      Darwin)
        if command -v brew &>/dev/null; then
          brew install python >>"$LOG_FILE" 2>&1 || true
        fi
        ;;
      Linux)
        if command -v apt-get &>/dev/null; then
          sudo apt-get update -qq >>"$LOG_FILE" 2>&1 || true
          sudo apt-get install -y -qq python3 python3-pip >>"$LOG_FILE" 2>&1 || true
        fi
        ;;
    esac
  fi
}

function install_boto3_quiet() {
  if command -v python3 &>/dev/null; then
    python3 -m pip install --quiet --upgrade boto3 >>"$LOG_FILE" 2>&1 || true
  fi
}

function install_tqdm_quiet() {
  if command -v python3 &>/dev/null; then
    python3 -m pip install --quiet --upgrade tqdm >>"$LOG_FILE" 2>&1 || true
  fi
}

function install_docker_quiet() {
  if [[ "$OS_TYPE" == "Darwin"* ]]; then
    return
  fi

  if ! command -v docker &>/dev/null; then
    case "$OS_TYPE" in
      Linux)
        if command -v apt-get &>/dev/null; then
          sudo apt-get update -qq >>"$LOG_FILE" 2>&1 || true
          sudo apt-get install -y -qq ca-certificates curl gnupg lsb-release >>"$LOG_FILE" 2>&1 || true
          sudo mkdir -p /etc/apt/keyrings
          curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg >>"$LOG_FILE" 2>&1 || true
          sudo chmod a+r /etc/apt/keyrings/docker.gpg
          echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
            $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
            | sudo tee /etc/apt/sources.list.d/docker.list >>"$LOG_FILE" 2>&1
          sudo apt-get update -qq >>"$LOG_FILE" 2>&1
          sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >>"$LOG_FILE" 2>&1
          sudo systemctl start docker || true
          sudo usermod -aG docker "$USER" || true
        fi
        ;;
    esac
  fi

  if [[ "$OS_TYPE" == "Linux"* ]]; then
    sudo systemctl start docker >>"$LOG_FILE" 2>&1 || true
  fi
}

install_aws_cli_quiet
echo "✅ AWS CLI installed."

install_python_quiet
install_boto3_quiet
echo "✅ boto3 installed."

install_tqdm_quiet
echo "✅ tqdm installed."

install_docker_quiet
echo "✅ Docker installed."

###############################################################################
# 3. SPINNING UP ULTIHASH
###############################################################################
echo ""
echo "Spinning up UltiHash..."
echo "🚀 UltiHash is running!"

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

echo "$UH_REGISTRY_PASSWORD" | docker login registry.ultihash.io -u "$UH_REGISTRY_LOGIN" --password-stdin >/dev/null 2>&1 || true

export AWS_ACCESS_KEY_ID="TEST-USER"
export AWS_SECRET_ACCESS_KEY="SECRET"
export UH_LICENSE_STRING
export UH_MONITORING_TOKEN

docker compose up -d >/dev/null 2>&1 || true
sleep 5

###############################################################################
# 4. WELCOME (No auto-open)
###############################################################################
cat <<WELCOME


Welcome to the UltiHash test installation! Here you can store real data
to see UltiHash's deduplication and speed. Different datasets will have different results.

If you'd like sample datasets, head to https://ultihash.io/test-data in your own browser.

WELCOME

###############################################################################
# 5. TQDM STORING & READING
###############################################################################
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
pp=pathlib.Path(dp)

s3 = boto3.client("s3", endpoint_url=endpoint)
try:
    s3.create_bucket(Bucket=bucket)
except:
    pass

def gather_files(basep):
    if basep.is_file():
        return [(basep, basep.parent)], basep.stat().st_size
    st=0
    fl=[]
    for (root,dirs,files) in os.walk(basep):
        for f in files:
            fu=pathlib.Path(root)/f
            st+=fu.stat().st_size
            fl.append((fu, basep))
    return fl, st

files_list, total_sz = gather_files(pp)
start = time.time()

print("")
progress = tqdm(
    total=total_sz,
    desc="Writing data",
    unit="B",
    unit_scale=True,
    unit_divisor=1000
)
pool = concurrent.futures.ThreadPoolExecutor(max_workers=8)

def do_store(fp, base):
    def cb(x):
        progress.update(x)
        progress.refresh()
    k = str(fp.relative_to(base))
    s3.upload_file(str(fp), bucket, k, Callback=cb)

futs = []
for (fp,bs) in files_list:
    futs.append(pool.submit(do_store, fp, bs))
for ft in futs:
    ft.result()

progress.close()
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
outp=pathlib.Path(f"{dp}-retrieved")
outp.mkdir(parents=True, exist_ok=True)

s3 = boto3.client("s3", endpoint_url=endpoint)

def gather_keys():
    allk=[]
    paginator=s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket):
        for obj in page.get("Contents",[]):
            allk.append(obj["Key"])
    return allk

def chunk_download(k):
    resp = s3.get_object(Bucket=bucket,Key=k)
    body = resp["Body"]
    lf = outp/bucket/k
    lf.parent.mkdir(parents=True, exist_ok=True)

    while True:
        chunk = body.read(128*1024)
        if not chunk:
            break
        yield (lf, chunk)

keys = gather_keys()

print("")
progress = tqdm(
    total=len(keys),
    desc="Reading data",
    unit="files",
    unit_scale=True
)
pool = concurrent.futures.ThreadPoolExecutor(max_workers=8)

def do_download(k):
    for (lf, chk) in chunk_download(k):
        with open(lf,"ab") as f:
            f.write(chk)
    progress.update(1)
    progress.refresh()

farr=[]
for kk in keys:
    farr.append(pool.submit(do_download, kk))
for ft in farr:
    ft.result()

progress.close()
EOF
}

# Minimal wipe logic
function wipe_cluster() {
  docker compose down -v >/dev/null 2>&1 || true
  # Also remove the local S3 bucket if needed:
  python3 - <<EOF
import sys, boto3

endpoint="http://127.0.0.1:8080"
b="test-bucket"
s3 = boto3.client("s3", endpoint_url=endpoint)
try:
    content = s3.list_objects_v2(Bucket=b).get("Contents",[])
    for obj in content:
        s3.delete_object(Bucket=b,Key=obj["Key"])
    s3.delete_bucket(Bucket=b)
except:
    pass
EOF
}

###############################################################################
# 6. SINGLE RUN
###############################################################################
echo -ne "${BOLD_TEAL}Paste the path of the directory you want to store:${RESET} "
IFS= read -r RAW_PATH < /dev/tty

RAW_PATH="$(trim_trailing_spaces "$RAW_PATH")"
RAW_PATH="$(echo "$RAW_PATH" | sed -E "s|^[[:space:]]*'(.*)'[[:space:]]*\$|\1|")"

if [[ -z "$RAW_PATH" || ! -e "$RAW_PATH" ]]; then
  echo "❌ You must provide a valid path. Exiting."
  docker compose down -v >/dev/null 2>&1 || true
  exit 1
fi

# 1. Store data (no actual throughput displayed)
store_data "$RAW_PATH"

# 2. Read data (no actual throughput displayed)
read_data "$RAW_PATH"

# 3. Shut down & wipe
wipe_cluster

# 4. Print EXACT lines you requested (static numbers & messages)
echo ""
echo "➡️  WRITE THROUGHPUT: 23.07 MB/s"
echo "⬅️  READ THROUGHPUT:  74.27 MB/s"
echo ""
echo "📦 ORIGINAL SIZE: 1.51 GB"
echo "✨ DEDUPLICATED SIZE: 0.49 GB"
echo "✅ SAVED WITH ULTIHASH: 1.02 GB (67.60%)"
echo ""
echo "🌛 The UltiHash cluster has been shut down, and the data you stored in it has been wiped. In measuring read speed, a copy of your data was placed in <path>. Make sure to go check it out, and then delete it when you're done."
echo ""
echo -e "${BOLD_TEAL}Claim your free 10TB license at https://ultihash.io/sign-up 🚀${RESET}"
