#!/usr/bin/env bash
#
# setup-devops-al2.sh
# Provisions a DevOps/Platform Engineering workspace on Amazon Linux 2 (yum-based),
# with the Progress Rail tooling (AWS SSO profiles, CodeCommit, Terraform via tfenv,
# SSM, MSK/Kafka with IAM auth).
#
# Usage:
#   chmod +x setup-devops-al2.sh
#   ./setup-devops-al2.sh              # install everything
#   ./setup-devops-al2.sh --no-gui     # skip VS Code (useful on headless servers)
#
# Idempotent: safe to re-run without breaking anything.

set -euo pipefail

# ---------- versions (pin here) ----------
TERRAFORM_VERSION="1.10.5"      # iac_ds_platform_kub_pipeline requires >= 1.10
KAFKA_VERSION="3.7.2"           # Kafka CLI (kafka-topics.sh, console producer/consumer)
KAFKA_SCALA="2.13"
MSK_IAM_AUTH_VERSION="2.2.0"    # aws-msk-iam-auth jar for the Kafka CLI

# ---------- helpers ----------
log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

INSTALL_GUI=true
[[ "${1:-}" == "--no-gui" ]] && INSTALL_GUI=false

ARCH="$(uname -m)"   # x86_64 or aarch64
case "$ARCH" in
  x86_64)  GO_ARCH="amd64" ;;
  aarch64) GO_ARCH="arm64" ;;
  *) warn "Unsupported architecture: $ARCH"; exit 1 ;;
esac
log "Detected architecture: ${ARCH}"

# ---------- 0. system base ----------
log "Updating the system and installing base packages"
sudo yum -y update
sudo yum -y install \
  curl wget git unzip tar gzip jq \
  bind-utils nmap-ncat telnet \
  vim nano tmux htop tree \
  bash-completion \
  gcc make openssl-devel \
  python3 python3-pip \
  which findutils \
  yum-utils

# Development tools group (compilers, etc.) — useful for builds
sudo yum -y groupinstall "Development Tools" || true

# ---------- 1. AWS CLI v2 ----------
# WorkSpaces AL2 ships AWS CLI v1 on Python 2.7. Check for v2 specifically so we
# actually upgrade (v2 lands in /usr/local/bin and wins in PATH over the v1).
if ! aws --version 2>&1 | grep -q 'aws-cli/2'; then
  log "Installing AWS CLI v2 (upgrading any preinstalled v1)"
  tmp="$(mktemp -d)"
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip" -o "$tmp/awscliv2.zip"
  unzip -q "$tmp/awscliv2.zip" -d "$tmp"
  sudo "$tmp/aws/install" --update
  rm -rf "$tmp"
else
  log "AWS CLI v2 already installed: $(aws --version 2>&1)"
fi

# ---------- 2. AWS SSO profiles (Progress Rail) ----------
# All accounts are reached through the SSO session "progressrail":
# pr-art-tools (SSO) -> assume "operator" in each account.
AWS_CONFIG="$HOME/.aws/config"
mkdir -p "$HOME/.aws"
touch "$AWS_CONFIG"

if ! grep -q '^\[sso-session progressrail\]' "$AWS_CONFIG"; then
  log "Adding Progress Rail SSO session and profiles to ~/.aws/config"
  cp "$AWS_CONFIG" "$AWS_CONFIG.bak.$(date +%Y%m%d%H%M%S)"
  cat >> "$AWS_CONFIG" <<'EOF'

[sso-session progressrail]
sso_start_url = https://progressrail-aws.awsapps.com/start/#/
sso_region = us-east-1
sso_registration_scopes = sso:account:access

[profile pr-art-tools]
sso_session = progressrail
sso_account_id = 338122153030
sso_role_name = ART-TOOLS-ACCOUNT-ACCESS
region = us-east-1
output = json

[profile pr-art-tools2]
role_arn = arn:aws:iam::338122153030:role/operator
source_profile = pr-art-tools
region = us-east-1
output = json

[profile pr-art-dev]
role_arn = arn:aws:iam::965541273308:role/operator
source_profile = pr-art-tools
region = us-east-1
output = json

[profile pr-art-test]
role_arn = arn:aws:iam::986135097693:role/operator
source_profile = pr-art-tools
region = us-east-1
output = json

[profile pr-art-staging]
role_arn = arn:aws:iam::641921558249:role/operator
source_profile = pr-art-tools
region = us-east-1
output = json

[profile pr-art-prod]
role_arn = arn:aws:iam::752864898908:role/operator
source_profile = pr-art-tools
region = us-east-1
output = json
EOF
else
  log "Progress Rail SSO profiles already in ~/.aws/config"
fi

# ---------- 3. Session Manager plugin (SSM into msk-client and other EC2) ----------
if ! have session-manager-plugin; then
  log "Installing AWS Session Manager plugin"
  case "$ARCH" in
    x86_64)  SSM_PATH="linux_64bit" ;;
    aarch64) SSM_PATH="linux_arm64" ;;
  esac
  sudo yum -y install \
    "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/${SSM_PATH}/session-manager-plugin.rpm"
else
  log "Session Manager plugin already installed"
fi

# ---------- 4. CodeCommit (git over HTTPS with the AWS credential helper) ----------
# Repos live in the tools account (pr-art-tools2). git-remote-codecommit also
# enables clone URLs like: codecommit::us-east-1://pr-art-tools2@<repo>
if ! git config --global --get-regexp '^credential\.https://git-codecommit' >/dev/null 2>&1; then
  log "Configuring git credential helper for CodeCommit (profile pr-art-tools2)"
  git config --global 'credential.https://git-codecommit.us-east-1.amazonaws.com.helper' \
    '!aws --profile pr-art-tools2 codecommit credential-helper $@'
  git config --global 'credential.https://git-codecommit.us-east-1.amazonaws.com.UseHttpPath' true
else
  log "CodeCommit credential helper already configured"
fi

if ! have git-remote-codecommit; then
  log "Installing git-remote-codecommit (pip, user scope)"
  python3 -m pip install --user git-remote-codecommit
fi

# ---------- 5. Docker (via amazon-linux-extras on AL2, yum fallback) ----------
if ! have docker; then
  log "Installing Docker"
  if have amazon-linux-extras; then
    sudo amazon-linux-extras install -y docker
  else
    sudo yum -y install docker
  fi
  sudo systemctl enable --now docker
  sudo usermod -aG docker "$USER"
  warn "You need to start a new session (logout/login) to use docker without sudo."
else
  log "Docker already installed: $(docker --version)"
fi

# docker compose (v2 plugin)
if ! docker compose version >/dev/null 2>&1; then
  log "Installing docker compose v2 plugin"
  DC_DIR="/usr/libexec/docker/cli-plugins"
  sudo mkdir -p "$DC_DIR"
  sudo curl -fsSL \
    "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${ARCH}" \
    -o "$DC_DIR/docker-compose"
  sudo chmod +x "$DC_DIR/docker-compose"
fi

# ---------- 6. kubectl ----------
if ! have kubectl; then
  log "Installing kubectl"
  KVER="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSL "https://dl.k8s.io/release/${KVER}/bin/linux/${GO_ARCH}/kubectl" -o /tmp/kubectl
  sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
  rm -f /tmp/kubectl
  kubectl completion bash | sudo tee /etc/bash_completion.d/kubectl >/dev/null
else
  log "kubectl already installed: $(kubectl version --client -o yaml 2>/dev/null | grep gitVersion | head -1)"
fi

# ---------- 7. Helm ----------
if ! have helm; then
  log "Installing Helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
  log "Helm already installed: $(helm version --short)"
fi

# ---------- 8. eksctl ----------
if ! have eksctl; then
  log "Installing eksctl"
  curl -fsSL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_${GO_ARCH}.tar.gz" \
    | sudo tar -xz -C /usr/local/bin
fi

# ---------- 9. Terraform via tfenv (pinned) ----------
# The repos pin Terraform versions; tfenv lets us switch per repo.
if [[ ! -d "$HOME/.tfenv" ]]; then
  log "Installing tfenv"
  git clone --depth 1 https://github.com/tfutils/tfenv.git "$HOME/.tfenv"
fi
mkdir -p "$HOME/.local/bin"
ln -sf "$HOME/.tfenv/bin/tfenv"     "$HOME/.local/bin/tfenv"
ln -sf "$HOME/.tfenv/bin/terraform" "$HOME/.local/bin/terraform"
export PATH="$HOME/.local/bin:$PATH"

if ! tfenv list 2>/dev/null | grep -q "$TERRAFORM_VERSION"; then
  log "Installing Terraform $TERRAFORM_VERSION"
  tfenv install "$TERRAFORM_VERSION"
fi
tfenv use "$TERRAFORM_VERSION" >/dev/null

# ---------- 10. Ansible ----------
if ! have ansible; then
  log "Installing Ansible (pip, user scope)"
  python3 -m pip install --user --upgrade pip
  python3 -m pip install --user ansible
else
  log "Ansible already installed: $(ansible --version | head -1)"
fi

# ---------- 11. yq ----------
if ! have yq; then
  log "Installing yq"
  sudo curl -fsSL \
    "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${GO_ARCH}" \
    -o /usr/local/bin/yq
  sudo chmod +x /usr/local/bin/yq
else
  log "yq already installed: $(yq --version)"
fi

# ---------- 12. Kafka CLI with MSK IAM auth ----------
# Our MSK clusters use IAM auth on port 9098. The Kafka CLI needs Java and the
# aws-msk-iam-auth jar; client-iam.properties holds the IAM settings.
KAFKA_HOME="/opt/kafka"
if [[ ! -x "$KAFKA_HOME/bin/kafka-topics.sh" ]]; then
  log "Installing Java (Amazon Corretto 17) and Kafka CLI $KAFKA_VERSION"
  sudo yum -y install java-17-amazon-corretto-headless
  tmp="$(mktemp -d)"
  curl -fsSL "https://archive.apache.org/dist/kafka/${KAFKA_VERSION}/kafka_${KAFKA_SCALA}-${KAFKA_VERSION}.tgz" \
    -o "$tmp/kafka.tgz"
  sudo mkdir -p "$KAFKA_HOME"
  sudo tar -xzf "$tmp/kafka.tgz" -C "$KAFKA_HOME" --strip-components=1
  rm -rf "$tmp"
else
  log "Kafka CLI already installed in $KAFKA_HOME"
fi

MSK_JAR="$KAFKA_HOME/libs/aws-msk-iam-auth-${MSK_IAM_AUTH_VERSION}-all.jar"
if [[ ! -f "$MSK_JAR" ]]; then
  log "Installing aws-msk-iam-auth $MSK_IAM_AUTH_VERSION"
  sudo curl -fsSL \
    "https://github.com/aws/aws-msk-iam-auth/releases/download/v${MSK_IAM_AUTH_VERSION}/aws-msk-iam-auth-${MSK_IAM_AUTH_VERSION}-all.jar" \
    -o "$MSK_JAR"
fi

if [[ ! -f "$HOME/kafka/client-iam.properties" ]]; then
  mkdir -p "$HOME/kafka"
  cat > "$HOME/kafka/client-iam.properties" <<'EOF'
security.protocol=SASL_SSL
sasl.mechanism=AWS_MSK_IAM
sasl.jaas.config=software.amazon.msk.auth.iam.IAMLoginModule required;
sasl.client.callback.handler.class=software.amazon.msk.auth.iam.IAMClientCallbackHandler
EOF
fi

# Python clients (kafka-python needs the OAUTHBEARER signer for MSK IAM)
log "Installing Python libs for Kafka/AWS (pip, user scope)"
python3 -m pip install --user --upgrade boto3 kafka-python pika \
  || warn "Some Python libs failed to install"
python3 -m pip install --user aws-msk-iam-sasl-signer-python \
  || warn "aws-msk-iam-sasl-signer-python needs Python >= 3.8 (AL2 ships 3.7). Use a newer python3 if needed."

# ---------- 13. VS Code ----------
# AL2 ships glibc 2.26; VS Code >= 1.86 requires glibc 2.28 (Microsoft dropped
# AL2/CentOS7/RHEL7 support in Jan 2024). Pin to 1.85.2, the last compatible build.
if $INSTALL_GUI; then
  if ! have code; then
    log "Installing VS Code (pinned to 1.85.2 — last glibc-2.26 compatible build)"
    sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
    sudo tee /etc/yum.repos.d/vscode.repo >/dev/null <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
    if ! sudo yum -y install code-1.85.2; then
      warn "Could not install code-1.85.2 via yum. Alternatives:"
      warn "  - List available builds:  yum --showduplicates list code | grep 1.85"
      warn "  - Or use VS Code Remote-SSH from your local machine into this host."
    fi
  else
    log "VS Code already installed: $(code --version | head -1)"
  fi
else
  warn "--no-gui flag set: skipping VS Code"
fi

# ---------- 14. Shell helpers (Progress Rail) ----------
PR_RC="$HOME/.progressrail.sh"
cat > "$PR_RC" <<'EOF'
# Progress Rail shell helpers (generated by setup-devops-al2.sh)
export PATH="$HOME/.local/bin:/opt/kafka/bin:$PATH"
export AWS_REGION=us-east-1

# SSO login (session expires often)
alias prlogin='aws sso login --sso-session progressrail'

# Switch account: prenv dev|test|staging|prod|tools
prenv() {
  case "$1" in
    dev)     export AWS_PROFILE=pr-art-dev ;;
    test)    export AWS_PROFILE=pr-art-test ;;
    staging) export AWS_PROFILE=pr-art-staging ;;
    prod)    export AWS_PROFILE=pr-art-prod ;;
    tools)   export AWS_PROFILE=pr-art-tools2 ;;
    *) echo "usage: prenv dev|test|staging|prod|tools"; return 1 ;;
  esac
  aws sts get-caller-identity --query Arn --output text
}

# Kafka CLI with IAM auth: kt --bootstrap-server <broker>:9098 --list
alias kt='kafka-topics.sh --command-config $HOME/kafka/client-iam.properties'

# Kafka UIs (internal, VPN only)
# prd: http://10.40.99.25:8080   stg: http://10.40.103.26:8080   tst: http://10.40.96.156:8080
EOF

if ! grep -q 'progressrail.sh' "$HOME/.bashrc"; then
  echo '[ -f "$HOME/.progressrail.sh" ] && source "$HOME/.progressrail.sh"' >> "$HOME/.bashrc"
fi

# ---------- summary ----------
tool_version() {
  case "$1" in
    kubectl) kubectl version --client -o yaml 2>/dev/null | awk '/gitVersion/{print $2; exit}' ;;
    helm)    helm version --short 2>/dev/null ;;
    eksctl)  eksctl version 2>/dev/null ;;
    ansible) ansible --version 2>/dev/null | head -1 ;;
    terraform) terraform version 2>/dev/null | head -1 ;;
    session-manager-plugin) session-manager-plugin --version 2>/dev/null ;;
    kafka-topics.sh) kafka-topics.sh --version 2>/dev/null | head -1 ;;
    java)    java -version 2>&1 | head -1 ;;
    *)       "$1" --version 2>/dev/null | head -1 ;;
  esac
}

export PATH="$HOME/.local/bin:/opt/kafka/bin:$PATH"
echo
log "Setup complete. Installed versions:"
for bin in aws session-manager-plugin docker kubectl helm eksctl terraform tfenv ansible yq java kafka-topics.sh git-remote-codecommit code; do
  if have "$bin"; then
    printf '   %-24s %s\n' "$bin" "$(tool_version "$bin")"
  fi
done

echo
warn "Next steps:"
warn " - Open a new shell (or: source ~/.bashrc) to load PATH and the Progress Rail helpers."
warn " - Log out and back in for the 'docker' group to take effect."
warn " - Log in to AWS:   prlogin"
warn " - Pick an account: prenv dev | test | staging | prod | tools"
