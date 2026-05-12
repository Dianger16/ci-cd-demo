#!/usr/bin/env bash
# ec2_setup.sh
# Run this ONCE on a fresh EC2 instance (Amazon Linux 2 or Ubuntu 22.04)
# to install Docker and prepare the server for deployments.
#
# How to run:
#   ssh -i your-key.pem ec2-user@YOUR_EC2_IP
#   curl -sO https://raw.githubusercontent.com/YOUR_USERNAME/cicd-demo/main/scripts/ec2_setup.sh
#   chmod +x ec2_setup.sh && bash ec2_setup.sh

set -euo pipefail

echo "══════════════════════════════════════"
echo "  EC2 Setup — Docker + project folder"
echo "══════════════════════════════════════"

# ── Detect OS ────────────────────────────────────────────────────────────────
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS=$ID
else
  OS="unknown"
fi

echo "Detected OS: $OS"

# ── Install Docker ───────────────────────────────────────────────────────────
if command -v docker &>/dev/null; then
  echo "Docker already installed: $(docker --version)"
else
  echo "Installing Docker..."

  if [ "$OS" = "amzn" ]; then
    # Amazon Linux 2
    sudo yum update -y
    sudo yum install -y docker
    sudo systemctl start docker
    sudo systemctl enable docker

  elif [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
    # Ubuntu / Debian
    sudo apt-get update -y
    sudo apt-get install -y ca-certificates curl gnupg
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io

  else
    echo "Unsupported OS: $OS. Install Docker manually."
    exit 1
  fi

  echo "Docker installed: $(docker --version)"
fi

# ── Add current user to docker group (no sudo needed) ───────────────────────
CURRENT_USER="${USER:-ec2-user}"
if ! groups "$CURRENT_USER" | grep -q docker; then
  sudo usermod -aG docker "$CURRENT_USER"
  echo "Added $CURRENT_USER to docker group."
  echo "NOTE: Log out and back in, or run: newgrp docker"
fi

# ── Install Docker Compose plugin ───────────────────────────────────────────
if ! docker compose version &>/dev/null 2>&1; then
  echo "Installing Docker Compose plugin..."
  COMPOSE_VERSION="v2.24.0"
  sudo mkdir -p /usr/local/lib/docker/cli-plugins
  sudo curl -SL \
    "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-$(uname -m)" \
    -o /usr/local/lib/docker/cli-plugins/docker-compose
  sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  echo "Docker Compose: $(docker compose version)"
fi

# ── Create project directory ─────────────────────────────────────────────────
mkdir -p "$HOME/cicd-demo/scripts"
echo "Project directory created: $HOME/cicd-demo"

# ── Open firewall port 3000 (if ufw is active) ──────────────────────────────
if command -v ufw &>/dev/null && sudo ufw status | grep -q "active"; then
  sudo ufw allow 3000/tcp
  echo "UFW: port 3000 opened."
fi

echo ""
echo "══════════════════════════════════════"
echo "  Setup complete!"
echo ""
echo "  Next steps:"
echo "  1. Log out and back in (for docker group)"
echo "  2. Add GitHub Secrets (see README)"
echo "  3. Push code to trigger the pipeline"
echo "══════════════════════════════════════"
