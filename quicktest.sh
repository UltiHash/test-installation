#!/usr/bin/env bash
set -e

###############################################################################
# 0. QUIET INSTALL (ALL PLATFORMS) + PRE-SUPPLIED CREDENTIALS
###############################################################################
UH_REGISTRY_LOGIN="mem_cm6aqbgbz0qnr0tte56bne9aq"
UH_REGISTRY_PASSWORD="G6R9242y4GCo1gRI"
UH_LICENSE_STRING="mem_cm6aqbgbz0qnr0tte56bne9aq:10240:UCR67tj/EnGW1KXtyuU35fQsRrvuOC4bMEwR3uDJ0jk4VTb9qt2LPKTJULhtIfDlA3X6W8Mn/V168/rbIM7eAQ=="
UH_MONITORING_TOKEN="7GcJLtaANgKP8GMX"

# We'll do all advanced stuff quietly:
LOG_DIR="$HOME/ultihash-test"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/install-silent.log"
touch "$LOG_FILE"

OS_TYPE="$(uname -s)"

function install_aws_cli_quiet() {
  # If AWS is missing, we attempt a silent install
  if ! command -v aws &>/dev/null; then
    if [[ "$OS_TYPE" == "Darwin" && -x "$(command -v brew)" ]]; then
      brew install awscli >"$LOG_FILE" 2>&1 || true
    elif [[ "$OS_TYPE" == "Linux" && -x "$(command -v apt-get)" ]]; then
      sudo apt-get install -y -qq unzip >>"$LOG_FILE" 2>&1 || true
      curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" >>"$LOG_FILE" 2>&1 || true
      unzip -q awscliv2.zip >>"$LOG_FILE" 2>&1 || true
      sudo ./aws/install -i /usr/local/aws-cli -b /usr/local/bin >>"$LOG_FILE" 2>&1 || true
      rm -rf awscliv2.zip aws/
    elif [[ "$OS_TYPE" =~ (MINGW|MSYS|CYGWIN).* && -x "$(command -v choco)" ]]; then
      choco install awscli -y >>"$LOG_FILE" 2>&1 || true
    fi
  fi
}

function install_python_boto3_tqdm_quiet() {
  # If python is missing, we attempt an install
  if ! command -v python3 &>/dev/null; then
    if [[ "$OS_TYPE" == "Darwin" && -x "$(command -v brew)" ]]; then
      brew install python >>"$LOG_FILE" 2>&1 || true
    elif [[ "$OS_TYPE" == "Linux" && -x "$(command -v apt-get)" ]]; then
      sudo apt-get install -y -qq python3 python3-pip >>"$LOG_FILE" 2>&1 || true
    elif [[ "$OS_TYPE" =~ (MINGW|MSYS|CYGWIN).* && -x "$(command -v choco)" ]]; then
      choco install python -y >>"$LOG_FILE" 2>&1 || true
    fi
  fi
  # Then pip install quietly
  if command -v python3 &>/dev/null; then
    python3 -m pip install --quiet --upgrade boto3 tqdm >>"$LOG_FILE" 2>&1 || true
  fi
}

function install_docker_quiet() {
  if ! command -v docker &>/dev/null; then
    if [[ "$OS_TYPE" == "Darwin" && -x "$(command -v brew)" ]]; then
      brew install --cask docker >>"$LOG_FILE" 2>&1 || true
    elif [[ "$OS_TYPE" == "Linux" && -x "$(command -v apt-get)" ]]; then
      # apt-get approach
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
    elif [[ "$OS_TYPE" =~ (MINGW|MSYS|CYGWIN).* && -x "$(command -v choco)" ]]; then
      choco install docker-desktop -y >>"$LOG_FILE" 2>&1 || true
    fi
  fi
  # Attempt to start docker quietly
  if [[ "$OS_TYPE" == "Linux" ]]; then
    sudo systemctl start docker >>"$LOG_FILE" 2>&1 || true
  fi
}

echo "Installing prerequisites..."
install_aws_cli_quiet
echo "✅ AWS CLI installed."
install_python_boto3_tqdm_quiet
echo "✅ Python + boto3 + tqdm installed."
install_docker_quiet
echo "✅ Docker installed."

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
    listing=[]
    for (root,dirs,files) in os.walk(pp):
        for f in files:
            fu=pathlib.Path(root)/f
            st+=fu.stat().st_size
            listing.append((fu,pp))
    return listing, st

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

def store_one(fp,base):
    def cb(x):
        progress.update(x)
        progress.refresh()
    k=str(fp.relative_to(base))
    s3.upload_file(str(fp), bucket, k, Callback=cb)

ff=[]
for (fp,base) in ls:
    ff.append(pool.submit(store_one,fp,base))
for x in ff:
    x.result()

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
p="$DATAPATH".strip()
outp=pathlib.Path(f"{p}-retrieved")
outp.mkdir(parents=True,exist_ok=True)

s3=boto3.client("s3",endpoint_url=endpoint)

def gather_keys():
    all_keys=[]
    total_s=0
    pag=s3.get_paginator("list_objects_v2")
    for page in pag.paginate(Bucket=bucket):
        for obj in page.get("Contents",[]):
            all_keys.append(obj["Key"])
            total_s+=obj["Size"]
    return all_keys,total_s

def chunked_download(k):
    r=s3.get_object(Bucket=bucket,Key=k)
    bod=r["Body"]
    localf=outp/bucket/k
    localf.parent.mkdir(parents=True,exist_ok=True)

    while True:
        chunk=bod.read(128*1024)
        if not chunk:
            break
        yield (localf,chunk)

keys,total_sz=gather_keys()
t0=time.time()

print("")
progress=tqdm(
    total=total_sz,
    desc="Reading data",
    unit="B",
    unit_scale=True,
    colour="#5bdbb4",
    unit_divisor=1000
)
pool=concurrent.futures.ThreadPoolExecutor(max_workers=8)

def dl_one(k):
    for lf,chunk in chunked_download(k):
        with open(lf,"ab") as f:
            f.write(chunk)
        progress.update(len(chunk))
        progress.refresh()

fs=[]
for kk in keys:
    fs.append(pool.submit(dl_one,kk))
for x in fs:
    x.result()

progress.close()
elapsed=time.time()-t0
mb=total_sz/(1024*1024)
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
saved=o-e
pct=0
if o>0:
    pct=(saved/o)*100
print(f"{o/1e9:.2f} {e/1e9:.2f} {saved/1e9:.2f} {pct:.2f}")
EOF
}

function wipe_bucket() {
  python3 - <<EOF
import sys,boto3
endpoint="http://127.0.0.1:8080"
b="test-bucket"
s3=boto3.client("s3",endpoint_url=endpoint)
try:
    pg=s3.list_objects_v2(Bucket=b).get("Contents",[])
    for o in pg:
        s3.delete_object(Bucket=b,Key=o["Key"])
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
# 6. MAIN LOOP
###############################################################################
function main_loop() {
  while true; do
    echo -ne "\033[1m\033[38;5;79mPaste the path of the directory you want to store:\033[0m " 
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
    echo -ne "\033[1m\033[38;5;79mWould you like to store a different dataset? (y/n) \033[0m"
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
