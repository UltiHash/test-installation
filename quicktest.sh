#!/bin/bash
set -e

###############################################################################
# 0. PRE-SUPPLIED CREDENTIALS / LICENSE
###############################################################################
UH_REGISTRY_LOGIN="mem_cm6aqbgbz0qnr0tte56bne9aq"
UH_REGISTRY_PASSWORD="G6R9242y4GCo1gRI"
UH_LICENSE_STRING="mem_cm6aqbgbz0qnr0tte56bne9aq:10240:UCR67tj/EnGW1KXtyuU35fQsRrvuOC4bMEwR3uDJ0jk4VTb9qt2LPKTJULhtIfDlA3X6W8Mn/V168/rbIM7eAQ=="
UH_MONITORING_TOKEN="7GcJLtaANgKP8GMX"

###############################################################################
# 1. COLORS & UTILITIES
###############################################################################
BOLD_TEAL="\033[1m\033[38;5;79m"
RESET="\033[0m"

function print_divider() {
  echo ""
  # Single continuous box-drawing line
  echo -e "${BOLD_TEAL}────────────────────────────────────────────────────${RESET}"
  echo ""
}

echo ""  # extra blank line

###############################################################################
# 2. INSTALLING PREREQUISITES
###############################################################################
echo "Installing prerequisites..."

sudo apt-get update -y -qq > /dev/null 2>&1

# Docker
if ! command -v docker &>/dev/null; then
  sudo apt-get install -y -qq ca-certificates curl gnupg lsb-release > /dev/null 2>&1
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor \
    -o /etc/apt/keyrings/docker.gpg > /dev/null 2>&1
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update -qq > /dev/null 2>&1
  sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null 2>&1
  sudo systemctl start docker
  sudo usermod -aG docker "$USER" || true
fi
if ! sudo systemctl is-active --quiet docker; then
  sudo systemctl start docker
fi
echo "✅ Docker installed."

# AWS CLI
if ! command -v aws &>/dev/null; then
  sudo apt-get install -y -qq unzip > /dev/null 2>&1
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
  unzip -q awscliv2.zip
  sudo ./aws/install -i /usr/local/aws-cli -b /usr/local/bin > /dev/null 2>&1 || true
  rm -rf awscliv2.zip aws/
fi
echo "✅ AWS CLI installed."

# Python + boto3 + tqdm
if ! command -v python3 &>/dev/null; then
  sudo apt-get install -y -qq python3 > /dev/null 2>&1
fi
sudo apt-get install -y -qq python3-boto3 python3-tqdm > /dev/null 2>&1
echo "✅ boto3 installed."

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

echo "$UH_REGISTRY_PASSWORD" | docker login registry.ultihash.io \
  -u "$UH_REGISTRY_LOGIN" --password-stdin > /dev/null 2>&1 || true

export AWS_ACCESS_KEY_ID="TEST-USER"
export AWS_SECRET_ACCESS_KEY="SECRET"
export UH_LICENSE_STRING="$UH_LICENSE_STRING"
export UH_MONITORING_TOKEN="$UH_MONITORING_TOKEN"

docker compose up -d > /dev/null 2>&1
sleep 5

echo ""
echo "🚀 UltiHash is running!"

###############################################################################
# 4. PRINT DIVIDER + WELCOME
###############################################################################
print_divider

echo "Welcome to the UltiHash test installation! Here you can store real data"
echo "to see UltiHash's deduplication and speed. Different datasets will have different results."
echo ""
echo "Head to https://ultihash.io/test-data to download sample datasets, or store your own."
echo ""

if command -v xdg-open &> /dev/null; then
  NO_AT_BRIDGE=1 xdg-open "https://ultihash.io/test-data" 2>/dev/null || true
fi

###############################################################################
# 5. DATASET LOOP
###############################################################################
store_and_check() {
  local DATAPATH="$1"

  python3 - <<EOF
import sys, os, pathlib, json, time
import concurrent.futures
import boto3
from tqdm import tqdm

endpoint = "http://127.0.0.1:8080"
bucket   = "test-bucket"
dp = "$DATAPATH".strip()
data_path = pathlib.Path(dp)

s3 = boto3.client("s3", endpoint_url=endpoint)
try:
    s3.create_bucket(Bucket=bucket)
except:
    pass

def gather_files(p):
    if p.is_file():
        return [(p, p.parent)], p.stat().st_size
    stotal=0
    flist=[]
    for (root, dirs, files) in os.walk(p):
        for f in files:
            full=pathlib.Path(root)/f
            stotal += full.stat().st_size
            flist.append((full,p))
    return flist, stotal

files_list, size_total = gather_files(data_path)
start_time = time.time()

print("")  # extra blank line before progress bar
progress = tqdm(
    total=size_total,
    unit="B",
    unit_scale=True,
    desc="Storing data",
    unit_divisor=1000,
    colour="#5bdbb4"   # teal-like hex color for the bar
)
pool = concurrent.futures.ThreadPoolExecutor(max_workers=8)

def store_one(fp, base):
    def cb(x):
        progress.update(x)
    key = str(fp.relative_to(base))
    s3.upload_file(str(fp), bucket, key, Callback=cb)

futs=[]
for (fp,base) in files_list:
    futs.append(pool.submit(store_one, fp, base))
for f in futs:
    f.result()

progress.close()
elapsed = time.time() - start_time

mb=size_total/(1024*1024)
tp=0
if elapsed>0:
    tp=mb/elapsed

print("")
print(f"⚡ THROUGHPUT: {tp:.2f} MB/s\n")

resp = s3.get_object(Bucket='ultihash', Key='v1/metrics/cluster')
data = json.loads(resp['Body'].read())

orig = data.get('raw_data_size', 0)
eff  = data.get('effective_data_size', 0)

orig_gb = orig/1e9
eff_gb  = eff/1e9
saved   = orig_gb - eff_gb
pct=0.0
if orig_gb>0:
    pct=(saved/orig_gb)*100

print(f"📦 ORIGINAL SIZE: {orig_gb:,.2f} GB")
print(f"✨ DEDUPLICATED SIZE: {eff_gb:,.2f} GB")
print(f"✅ SAVED WITH ULTIHASH: {saved:,.2f} GB ({pct:.2f}%)\n")

print("To unlock your free 10TB license, visit https://ultihash.io/signup 🚀")
if os.system("command -v xdg-open >/dev/null")==0:
    os.system("NO_AT_BRIDGE=1 xdg-open https://ultihash.io/signup 2>/dev/null")
EOF
}

wipe_bucket() {
  python3 - <<EOF
import sys,boto3

endpoint="http://127.0.0.1:8080"
bucket="test-bucket"
s3=boto3.client("s3",endpoint_url=endpoint)
try:
    objs=s3.list_objects_v2(Bucket=bucket).get("Contents",[])
    for o in objs:
        s3.delete_object(Bucket=bucket,Key=o["Key"])
    s3.delete_bucket(Bucket=bucket)
except:
    pass
EOF
}

wipe_cluster() {
  docker compose down -v > /dev/null 2>&1 || true
  wipe_bucket
}

main_loop() {
  while true; do
    echo -ne "${BOLD_TEAL}Paste the path of the directory you want to store:${RESET} " > /dev/tty
    IFS= read -r DATAPATH < /dev/tty

    # remove single quotes if they wrap entire path
    DATAPATH="$(echo "$DATAPATH" | sed -E "s|^[[:space:]]*'(.*)'[[:space:]]*\$|\1|")"

    if [[ -z "$DATAPATH" || ! -e "$DATAPATH" ]]; then
      echo "❌ You must provide a valid path. Please try again."
      continue
    fi

    store_and_check "$DATAPATH"

    echo ""
    echo -ne "Would you like to store a different dataset? (y/n) " > /dev/tty
    IFS= read -r ANSWER < /dev/tty
    if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
      wipe_cluster

      echo ""
      echo "Preparing the cluster..."
      docker compose up -d > /dev/null 2>&1
      sleep 5

      echo ""
      echo "Paste the path of the directory you want to store:"
    else
      echo ""
      echo "Shutting down UltiHash..."
      docker compose down -v > /dev/null 2>&1
      echo "🌛 UltiHash is offline."
      break
    fi
  done
}

main_loop
