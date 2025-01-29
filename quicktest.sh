#!/usr/bin/env bash
set -e

###############################################################################
# 0. MACOS DOCKER CHECK + PRE-SUPPLIED CREDENTIALS
###############################################################################
# This block ensures that on macOS, Docker Desktop is installed & running
# before we do anything else.

OS_TYPE="$(uname -s)"

if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "🔍 Checking Docker on macOS..."

    # 1) Confirm Docker is installed
    if ! command -v docker &> /dev/null; then
        echo "❌ Docker is not installed on this Mac!"
        echo "➡️  Download and install Docker Desktop from: https://www.docker.com/products/docker-desktop/"
        exit 1
    fi

    # 2) Confirm Docker Desktop is running
    if ! docker info &>/dev/null; then
        echo "❌ Docker Desktop is not running!"
        echo "🏁 Open Docker Desktop, wait for it to start, then press Enter to continue..."
        # flush any leftover input
        read -r  # Wait for the user to press Enter

        # Re-check
        if ! docker info &>/dev/null; then
            echo "❌ Docker Desktop is still not running. Please try again later."
            exit 1
        fi
    fi
fi

# Now define the credentials + license
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

function print_divider() {
  echo ""
  echo -e "${BOLD_TEAL}────────────────────────────────────────────────────${RESET}"
  echo ""
}

echo ""  # blank line before everything

###############################################################################
# 2. INSTALLING PREREQUISITES (AWS CLI → Python + boto3/tqdm → Docker)
#    in quiet mode for Linux / Windows. On macOS we already checked Docker above
###############################################################################
echo "Installing prerequisites..."

LOG_DIR="$HOME/ultihash-test"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/install-silent.log"
touch "$LOG_FILE"

# We'll define quiet install functions:
function install_aws_cli_quiet() {
  if ! command -v aws &>/dev/null; then
    case "$OS_TYPE" in
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
      Darwin)
        if command -v brew &>/dev/null; then
          brew install awscli >>"$LOG_FILE" 2>&1 || true
        fi
        ;;
      MINGW*|MSYS*|CYGWIN*)
        if command -v choco &>/dev/null; then
          choco install awscli -y >>"$LOG_FILE" 2>&1 || true
        fi
        ;;
    esac
  fi
}

function install_python_boto3_tqdm_quiet() {
  if ! command -v python3 &>/dev/null; then
    case "$OS_TYPE" in
      Linux)
        if command -v apt-get &>/dev/null; then
          sudo apt-get update -qq >>"$LOG_FILE" 2>&1 || true
          sudo apt-get install -y -qq python3 python3-pip >>"$LOG_FILE" 2>&1 || true
        fi
        ;;
      Darwin)
        if command -v brew &>/dev/null; then
          brew install python >>"$LOG_FILE" 2>&1 || true
        fi
        ;;
      MINGW*|MSYS*|CYGWIN*)
        if command -v choco &>/dev/null; then
          choco install python -y >>"$LOG_FILE" 2>&1 || true
        fi
        ;;
    esac
  fi
  # quietly pip install
  if command -v python3 &>/dev/null; then
    python3 -m pip install --quiet --upgrade boto3 tqdm >>"$LOG_FILE" 2>&1 || true
  fi
}

function install_docker_quiet() {
  # For Mac we skip because we rely on manual Docker Desktop
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
      MINGW*|MSYS*|CYGWIN*)
        if command -v choco &>/dev/null; then
          choco install docker-desktop -y >>"$LOG_FILE" 2>&1 || true
        fi
        ;;
    esac
  fi

  # Attempt to start Docker on Linux
  if [[ "$OS_TYPE" == "Linux"* ]]; then
    sudo systemctl start docker >>"$LOG_FILE" 2>&1 || true
  fi
}

# Do the quiet installs
install_aws_cli_quiet
echo "✅ AWS CLI installed."

install_python_boto3_tqdm_quiet
echo "✅ Python + boto3 + tqdm installed."

install_docker_quiet
# If on mac, we skip the auto-install
if [[ "$OS_TYPE" != "Darwin"* ]]; then
  echo "✅ Docker installed."
else
  echo "✅ Docker installed (on macOS, please open Docker.app)."
fi

###############################################################################
# 3. SPINNING UP ULTIHASH (quietly)
###############################################################################
echo ""
echo "Spinning up UltiHash..."
echo "🚀 UltiHash is running!"

ULTIHASH_DIR="$HOME/ultihash-test"
mkdir -p "$ULTIHASH_DIR"
cd "$ULTIHASH_DIR" 2>/dev/null || true

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
# 4. WELCOME
###############################################################################
cat <<WELCOME


Welcome to the UltiHash test installation! Here you can store real data
to see UltiHash's deduplication and speed. Different datasets will have different results.

Head to https://ultihash.io/test-data to download sample datasets, or store your own.

WELCOME

###############################################################################
# 5. TQDM-BASED STORING & READING
###############################################################################
function store_data() {
  local DATAPATH="$1"
  python3 - <<EOF
import sys, os, pathlib, json, time
import concurrent.futures
import boto3
from tqdm import tqdm

endpoint="http://127.0.0.1:8080"
bucket="test-bucket"

dp="$DATAPATH".strip()
p=pathlib.Path(dp)

s3=boto3.client("s3",endpoint_url=endpoint)
try:
    s3.create_bucket(Bucket=bucket)
except:
    pass

def gather_files(pp):
    if pp.is_file():
        return [(pp,pp.parent)], pp.stat().st_size
    st=0
    files_list=[]
    for (root,dirs,fils) in os.walk(pp):
        for f in fils:
            fu=pathlib.Path(root)/f
            st+=fu.stat().st_size
            files_list.append((fu,pp))
    return files_list, st

ls, total_sz=gather_files(p)
t0=time.time()

print("")
progress=tqdm(
    total=total_sz,
    desc="Writing data",
    unit="B",
    unit_scale=True,
    colour="#5bdbb4",
    unit_divisor=1000
)
pool=concurrent.futures.ThreadPoolExecutor(max_workers=8)

def do_store(fp,base):
    def cb(x):
        progress.update(x)
        progress.refresh()
    key=str(fp.relative_to(base))
    s3.upload_file(str(fp),bucket,key,Callback=cb)

futures=[]
for (fp,base) in ls:
    futures.append(pool.submit(do_store,fp,base))
for fut in futures:
    fut.result()

progress.close()
elapsed=time.time()-t0
mb=total_sz/(1024*1024)
wr=0
if elapsed>0:
    wr=mb/elapsed

print(f"{wr:.2f}")
EOF
}

function read_data() {
  local DATAPATH="$1"
  python3 - <<EOF
import sys,os,pathlib,time
import concurrent.futures
import boto3
from tqdm import tqdm

endpoint="http://127.0.0.1:8080"
bucket="test-bucket"

p_str="$DATAPATH".strip()
outp=pathlib.Path(f"{p_str}-retrieved")
outp.mkdir(parents=True,exist_ok=True)

s3=boto3.client("s3",endpoint_url=endpoint)

def gather_keys():
    allk=[]
    sum_s=0
    pag=s3.get_paginator("list_objects_v2")
    for page in pag.paginate(Bucket=bucket):
        for o in page.get("Contents",[]):
            allk.append(o["Key"])
            sum_s+=o["Size"]
    return allk,sum_s

def chunk_download(k):
    r=s3.get_object(Bucket=bucket,Key=k)
    body=r["Body"]
    lf=outp/bucket/k
    lf.parent.mkdir(parents=True,exist_ok=True)

    while True:
        chunk=body.read(128*1024)
        if not chunk:
            break
        yield (lf,chunk)

keys,total_s=gather_keys()
t0=time.time()

print("")
progress=tqdm(
    total=total_s,
    desc="Reading data",
    unit="B",
    unit_scale=True,
    colour="#5bdbb4",
    unit_divisor=1000
)
pool=concurrent.futures.ThreadPoolExecutor(max_workers=8)

def do_download(k):
    for lf,chunk in chunk_download(k):
        with open(lf,"ab") as f:
            f.write(chunk)
        progress.update(len(chunk))
        progress.refresh()

fs=[]
for kk in keys:
    fs.append(pool.submit(do_download,kk))
for x in fs:
    x.result()

progress.close()
elapsed=time.time()-t0
mb=total_s/(1024*1024)
rd=0
if elapsed>0:
    rd=mb/elapsed

print(f"{rd:.2f}")
EOF
}

function dedup_info() {
  python3 - <<EOF
import sys,json
import boto3

s3=boto3.client("s3",endpoint_url="http://127.0.0.1:8080")
resp=s3.get_object(Bucket="ultihash",Key="v1/metrics/cluster")
data=json.loads(resp["Body"].read())

o=data.get("raw_data_size",0)
e=data.get("effective_data_size",0)
sav=o-e
pct=0
if o>0:
    pct=(sav/o)*100
print(f"{o/1e9:.2f} {e/1e9:.2f} {sav/1e9:.2f} {pct:.2f}")
EOF
}

function wipe_bucket() {
  python3 - <<EOF
import sys,boto3

endpoint="http://127.0.0.1:8080"
b="test-bucket"
s3=boto3.client("s3",endpoint_url=endpoint)
try:
    pg=s3.list_objects_v2(Bucket=b)
    for ob in pg.get("Contents",[]):
        s3.delete_object(Bucket=b,Key=ob["Key"])
    s3.delete_bucket(Bucket=b)
except:
    pass
EOF
}

function wipe_cluster() {
  docker compose down -v || true
  wipe_bucket
}

###############################################################################
# 6. MAIN LOOP (store → read → results)
###############################################################################
function main_loop() {
  while true; do
    echo -ne "${BOLD_TEAL}Paste the path of the directory you want to store:${RESET} "
    IFS= read -r DATAPATH

    DATAPATH="$(echo "$DATAPATH" | sed -E "s|^[[:space:]]*'(.*)'[[:space:]]*\$|\1|")"
    if [[ -z "$DATAPATH" || ! -e "$DATAPATH" ]]; then
      echo "❌ You must provide a valid path. Please try again."
      continue
    fi

    # (A) blank line
    echo ""

    # Write
    WRITE_SPEED="$(store_data "$DATAPATH" | tr -d '\r\n')"

    # (B) blank line
    echo ""

    # Read
    READ_SPEED="$(read_data "$DATAPATH" | tr -d '\r\n')"

    # (C) blank line
    echo ""

    # Dedup stats
    DE_INFO="$(dedup_info)"
    ORIG_GB="$(echo "$DE_INFO" | awk '{print $1}')"
    EFF_GB="$(echo "$DE_INFO"  | awk '{print $2}')"
    SAV_GB="$(echo "$DE_INFO"  | awk '{print $3}')"
    PCT="$(echo "$DE_INFO"     | awk '{print $4}')"

    echo "➡️  WRITE THROUGHPUT: $WRITE_SPEED MB/s"
    echo "⬅️  READ THROUGHPUT:  $READ_SPEED MB/s"
    echo ""
    echo "📦 ORIGINAL SIZE: ${ORIG_GB} GB"
    echo "✨ DEDUPLICATED SIZE: ${EFF_GB} GB"
    echo "✅ SAVED WITH ULTIHASH: ${SAV_GB} GB (${PCT}%)"

    echo ""
    echo -ne "${BOLD_TEAL}${BOLD}Would you like to store a different dataset? (y/n) ${RESET}"
    IFS= read -r ANSWER

    if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
      docker compose down -v || true
      wipe_bucket

      echo ""
      echo "Preparing the cluster..."
      docker compose up -d || true
      sleep 5

      echo ""
    else
      echo ""
      echo "Shutting down UltiHash..."
      docker compose down -v || true
      echo "🌛 UltiHash is offline."
      break
    fi
  done
}

main_loop
