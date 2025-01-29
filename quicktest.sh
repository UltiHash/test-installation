#!/usr/bin/env bash
set -e

###############################################################################
# 0. OS DETECTION + UNIFIED INSTALL
###############################################################################
OS_TYPE="$(uname -s)"

function install_tools_linux() {
  # apt-get approach
  sudo apt-get update -qq
  # 1) AWS CLI
  if ! command -v aws &>/dev/null; then
    sudo apt-get install -y unzip
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip -q awscliv2.zip
    sudo ./aws/install -i /usr/local/aws-cli -b /usr/local/bin || true
    rm -rf awscliv2.zip aws/
  fi
  echo "✅ AWS CLI installed."

  # 2) Python + boto3 + tqdm
  if ! command -v python3 &>/dev/null; then
    sudo apt-get install -y python3
  fi
  # Guarantee pip if needed
  if ! command -v pip3 &>/dev/null; then
    sudo apt-get install -y python3-pip
  fi
  # Install boto3/tqdm
  python3 -m pip install --upgrade --user boto3 tqdm
  echo "✅ Python + boto3 + tqdm installed."

  # 3) Docker
  if ! command -v docker &>/dev/null; then
    sudo apt-get install -y ca-certificates curl gnupg lsb-release
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list
    sudo apt-get update -qq
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo systemctl start docker
    sudo usermod -aG docker "$USER" || true
  fi
  # Ensure docker is running
  if ! sudo systemctl is-active --quiet docker; then
    sudo systemctl start docker
  fi
  echo "✅ Docker installed."
}

function install_tools_mac() {
  # Homebrew approach
  # 1) AWS CLI
  if ! command -v aws &>/dev/null; then
    brew install awscli
  fi
  echo "✅ AWS CLI installed."

  # 2) Python + pip + boto3 + tqdm
  if ! command -v python3 &>/dev/null; then
    brew install python
  fi
  python3 -m pip install --upgrade --user boto3 tqdm
  echo "✅ Python + boto3 + tqdm installed."

  # 3) Docker
  if ! command -v docker &>/dev/null; then
    brew install --cask docker
    # The user must open Docker.app to start Docker Desktop
  fi
  echo "✅ Docker installed (on macOS, please open Docker.app)."
}

function install_tools_windows() {
  # If WSL, we might detect "Linux" in uname. If Git Bash, "MINGW"/"MSYS"/"CYGWIN"
  # We'll try a best-effort approach:
  UNAME_OUT="$(uname -s)"
  case "$UNAME_OUT" in
    *MINGW*|*MSYS*|*CYGWIN*)
      # Possibly Git Bash on Windows - no direct apt-get or brew
      # We instruct user or try choco if present
      if command -v choco &>/dev/null; then
        echo "Using choco to install AWS CLI, Python, Docker..."
        choco install awscli python docker-desktop
        # Then user must run Docker Desktop
      else
        echo "Cannot auto-install: please install Docker Desktop (windows), AWS CLI, Python, and run 'pip3 install boto3 tqdm'."
      fi
      ;;
    Linux)
      # Possibly WSL - let's do the Linux approach
      install_tools_linux
      ;;
    *)
      # Unknown
      echo "Unrecognized environment. Please install Docker, AWS CLI, python + boto3 + tqdm manually on Windows."
      ;;
  esac
}

echo ""  # blank line
# Identify platform
case "$OS_TYPE" in
  Linux)
    install_tools_linux
    ;;
  Darwin)
    install_tools_mac
    ;;
  *MINGW*|*MSYS*|*CYGWIN*)
    install_tools_windows
    ;;
  *)
    # Possibly unknown Unix, or Windows environment
    install_tools_windows
    ;;
esac

###############################################################################
# 3. SPINNING UP ULTIHASH
###############################################################################
echo ""
echo "Spinning up UltiHash..."
echo "🚀 UltiHash is running!"

ULTIHASH_DIR="$HOME/ultihash-test"
mkdir -p "$ULTIHASH_DIR"
cd "$ULTIHASH_DIR"

# Create policies.json
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

# compose.yml
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

# Docker login if needed
echo "$UH_REGISTRY_PASSWORD" | docker login registry.ultihash.io -u "$UH_REGISTRY_LOGIN" --password-stdin || true

# Exports for local usage if needed
export AWS_ACCESS_KEY_ID="TEST-USER"
export AWS_SECRET_ACCESS_KEY="SECRET"
export UH_LICENSE_STRING="$UH_LICENSE_STRING"
export UH_MONITORING_TOKEN="$UH_MONITORING_TOKEN"

docker compose up -d || true
sleep 5

###############################################################################
# 4. PRINT DIVIDER + WELCOME
###############################################################################
print_divider

echo "Welcome to the UltiHash test installation! Here you can store real data"
echo "to see UltiHash's deduplication and speed. Different datasets will have different results."
echo ""
echo "Head to https://ultihash.io/test-data to download sample datasets, or store your own."
echo ""

###############################################################################
# 5. store_data + read_data + dedup_info
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
data_path=pathlib.Path(dp)

s3=boto3.client("s3",endpoint_url=endpoint)
try:
    s3.create_bucket(Bucket=bucket)
except:
    pass

def gather_files(p):
    if p.is_file():
        return [(p,p.parent)], p.stat().st_size
    stotal=0
    fl=[]
    for rt,ds,fs in os.walk(p):
        for f in fs:
            fu=pathlib.Path(rt)/f
            stotal+=fu.stat().st_size
            fl.append((fu,p))
    return fl,stotal

files, total_s=gather_files(data_path)
t0=time.time()

print("")
progress=tqdm(
    total=total_s,
    desc="Writing data",
    unit="B",
    unit_scale=True,
    colour="#5bdbb4",
    unit_divisor=1000
)

pool=concurrent.futures.ThreadPoolExecutor(max_workers=8)

def store_one(fp,base):
    def cb(x):
        progress.update(x)
        progress.refresh()
    key=str(fp.relative_to(base))
    s3.upload_file(str(fp),bucket,key,Callback=cb)

fs=[]
for (fp,base) in files:
    fs.append(pool.submit(store_one,fp,base))
for x in fs:
    x.result()

progress.close()
elapsed=time.time()-t0
mb=total_s/(1024*1024)
wr=0
if elapsed>0:
    wr=mb/elapsed

print(f"{wr:.2f}")
EOF
}

function read_data() {
  local DATAPATH="$1"
  local OUTD="${DATAPATH}-retrieved"

  python3 - <<EOF
import sys,os,pathlib,time
import concurrent.futures
import boto3
from tqdm import tqdm

endpoint="http://127.0.0.1:8080"
bucket="test-bucket"
dp="$DATAPATH".strip()
outd_str=f"{dp}-retrieved"
outd=pathlib.Path(outd_str)
outd.mkdir(parents=True, exist_ok=True)

s3=boto3.client("s3",endpoint_url=endpoint)

def gather_keys():
    sum_s=0
    all_k=[]
    pag=s3.get_paginator("list_objects_v2")
    for page in pag.paginate(Bucket=bucket):
        for o in page.get("Contents",[]):
            all_k.append(o["Key"])
            sum_s+=o["Size"]
    return all_k,sum_s

def chunk_download(k):
    resp=s3.get_object(Bucket=bucket,Key=k)
    body=resp["Body"]
    lfile=outd/bucket/k
    lfile.parent.mkdir(parents=True,exist_ok=True)
    while True:
        chunk=body.read(128*1024)
        if not chunk:
            break
        yield (lfile,chunk)

keys, total_s=gather_keys()
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

def dl_one(k):
    for lf,chunk in chunk_download(k):
        with open(lf,"ab") as f:
            f.write(chunk)
        progress.update(len(chunk))
        progress.refresh()

pool=concurrent.futures.ThreadPoolExecutor(max_workers=8)
fs=[]
for k in keys:
    fs.append(pool.submit(dl_one,k))
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

orig=data.get("raw_data_size",0)
eff =data.get("effective_data_size",0)
sav =orig-eff
pct=0
if orig>0:
    pct=(sav/orig)*100
print(f"{orig/1e9:.2f} {eff/1e9:.2f} {sav/1e9:.2f} {pct:.2f}")
EOF
}

function wipe_bucket() {
  python3 - <<EOF
import sys,boto3

endpoint="http://127.0.0.1:8080"
bucket="test-bucket"
s3=boto3.client("s3",endpoint_url=endpoint)
try:
    p=s3.list_objects_v2(Bucket=bucket)
    for o in p.get("Contents",[]):
        s3.delete_object(Bucket=bucket,Key=o["Key"])
    s3.delete_bucket(Bucket=bucket)
except:
    pass
EOF
}

function wipe_cluster() {
  docker compose down -v || true
  wipe_bucket
}

###############################################################################
# 6. MAIN LOOP
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

    # Write data
    WRITE_SPEED="$(store_data "$DATAPATH" | tr -d '\r\n')"

    # (B) blank line
    echo ""

    # Read data
    READ_SPEED="$(read_data "$DATAPATH" | tr -d '\r\n')"

    # (C) blank line
    echo ""

    # dedup stats
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
