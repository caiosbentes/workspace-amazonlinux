#!/usr/bin/env bash
#
# setup-devops-al2.sh
# Provisions a DevOps/Platform Engineering workspace on Amazon Linux 2 (yum-based).
#
# Usage:
#   chmod +x setup-devops-al2.sh
#   ./setup-devops-al2.sh              # install everything
#   ./setup-devops-al2.sh --no-gui     # skip VS Code (useful on headless servers)
#
# Idempotent: safe to re-run without breaking anything.

set -euo pipefail

# ---------- helpers ----------
log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

INSTALL_GUI=true
[[ "${1:-}" == "--no-gui" ]] && INSTALL_GUI=false

ARCH="$(uname -m)"   # x86_64 or aarch64
log "Detected architecture: ${ARCH}"

# ---------- 0. system base ----------
log "Updating the system and installing base packages"
sudo yum -y update
sudo yum -y install \
  curl wget git unzip tar gzip jq \
  bind-utils \
  vim nano tmux htop tree \
  bash-completion \
  gcc make openssl-devel \
  python3 python3-pip \
  which findutils \
  yum-utils

# Development tools group (compilers, etc.) — useful for builds
sudo yum -y groupinstall "Development Tools" || true

# ---------- 1. AWS CLI v2 ----------
if ! have aws; then
  log "Installing AWS CLI v2"
  case "$ARCH" in
    x86_64)  AWS_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" ;;
    aarch64) AWS_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" ;;
  esac
  tmp="$(mktemp -d)"
  curl -fsSL "$AWS_URL" -o "$tmp/awscliv2.zip"
  unzip -q "$tmp/awscliv2.zip" -d "$tmp"
  sudo "$tmp/aws/install" --update
  rm -rf "$tmp"
else
  log "AWS CLI already installed: $(aws --version 2>&1)"
fi

# ---------- 2. Docker (via amazon-linux-extras on AL2, yum fallback) ----------
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
  case "$ARCH" in
    x86_64)  DC_ARCH="x86_64" ;;
    aarch64) DC_ARCH="aarch64" ;;
  esac
  sudo curl -fsSL \
    "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${DC_ARCH}" \
    -o "$DC_DIR/docker-compose"
  sudo chmod +x "$DC_DIR/docker-compose"
fi

# ---------- 3. kubectl ----------
if ! have kubectl; then
  log "Installing kubectl"
  case "$ARCH" in
    x86_64)  K_ARCH="amd64" ;;
    aarch64) K_ARCH="arm64" ;;
  esac
  KVER="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSL "https://dl.k8s.io/release/${KVER}/bin/linux/${K_ARCH}/kubectl" -o /tmp/kubectl
  sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
  rm -f /tmp/kubectl
  # shell autocompletion
  kubectl completion bash | sudo tee /etc/bash_completion.d/kubectl >/dev/null
else
  log "kubectl already installed: $(kubectl version --client -o yaml 2>/dev/null | grep gitVersion | head -1)"
fi

# ---------- 4. Helm ----------
if ! have helm; then
  log "Installing Helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
  log "Helm already installed: $(helm version --short)"
fi

# ---------- 5. Terraform (via HashiCorp repo) ----------
if ! have terraform; then
  log "Installing Terraform (HashiCorp repo)"
  sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
  sudo yum -y install terraform
else
  log "Terraform already installed: $(terraform version | head -1)"
fi

# ---------- 6. Ansible ----------
if ! have ansible; then
  log "Installing Ansible (pip, user scope)"
  python3 -m pip install --user --upgrade pip
  python3 -m pip install --user ansible
else
  log "Ansible already installed: $(ansible --version | head -1)"
fi

# ---------- 7. eksctl (bonus, useful for your EKS context) ----------
if ! have eksctl; then
  log "Installing eksctl"
  case "$ARCH" in
    x86_64)  E_ARCH="amd64" ;;
    aarch64) E_ARCH="arm64" ;;
  esac
  curl -fsSL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_${E_ARCH}.tar.gz" \
    | sudo tar -xz -C /usr/local/bin
fi

# ---------- 8. yq (official binary; not in default AL2 repos) ----------
if ! have yq; then
  log "Installing yq"
  case "$ARCH" in
    x86_64)  Y_ARCH="amd64" ;;
    aarch64) Y_ARCH="arm64" ;;
  esac
  sudo curl -fsSL \
    "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${Y_ARCH}" \
    -o /usr/local/bin/yq
  sudo chmod +x /usr/local/bin/yq
else
  log "yq already installed: $(yq --version)"
fi

# ---------- 9. VS Code ----------
if $INSTALL_GUI; then
  if ! have code; then
    log "Installing VS Code"
    sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
    sudo tee /etc/yum.repos.d/vscode.repo >/dev/null <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
    sudo yum -y install code
  else
    log "VS Code already installed: $(code --version | head -1)"
  fi
else
  warn "--no-gui flag set: skipping VS Code"
fi

# ---------- summary ----------
echo
log "Setup complete. Installed versions:"
for bin in aws docker kubectl helm terraform ansible eksctl yq code; do
  if have "$bin"; then
    printf '   %-10s %s\n' "$bin" "$($bin --version 2>&1 | head -1)"
  fi
done

echo
warn "Reminders:"
warn " - Log out and back in for the 'docker' group to take effect."
warn " - Add ~/.local/bin to your PATH if ansible is not found:"
warn "     echo 'export PATH=\$HOME/.local/bin:\$PATH' >> ~/.bashrc && source ~/.bashrc"
warn " - AL2 ships Python 3.7; pip will install an ansible version compatible with it."
