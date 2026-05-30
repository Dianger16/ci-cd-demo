# CI/CD  — Node.js + Docker + GitHub Actions + EC2

A production-style CI/CD pipeline that automatically tests, builds, and deploys a Node.js app to AWS EC2 using GitHub Actions, Docker Hub, and auto rollback on failure.

---

## How it works

Every push to `main` triggers a 3-stage pipeline:

```
Push to main
    │
    ▼
┌─────────┐     ┌───────────────────┐     ┌─────────────────────────┐
│  TEST   │────▶│  BUILD & PUSH     │────▶│  DEPLOY + AUTO ROLLBACK │
│  Jest   │     │  Docker Hub       │     │  EC2 via SSH            │
└─────────┘     └───────────────────┘     └─────────────────────────┘
```

- **Test** — runs Jest with coverage, uploads report as artifact
- **Build** — builds Docker image, tags it with the short commit SHA, pushes to Docker Hub
- **Deploy** — SSHes into EC2, pulls the new image, starts the container, runs health checks. If health checks fail, automatically rolls back to the previous image.

Pull requests only run the **test** job — build and deploy are skipped.

---

## Project structure

```
├── app/
│   ├── index.js          # Express app (/, /health endpoints)
│   ├── index.test.js     # Jest tests
│   ├── Dockerfile        # Node 22 Alpine image
│   └── package.json
├── scripts/
│   ├── deploy_ec2.sh     # Deploy + health check + rollback logic
│   ├── health_check.sh   # Standalone health check script
│   └── ec2_setup.sh      # One-time EC2 server setup
├── .github/
│   └── workflows/
│       └── deploy.yml    # GitHub Actions pipeline
└── docker-compose.yml    # Local development
```

---

## API endpoints

| Method | Path      | Description              |
|--------|-----------|--------------------------|
| GET    | `/`       | Returns app version info |
| GET    | `/health` | Health check endpoint    |

```json
// GET /health
{ "status": "healthy" }

// GET /
{ "message": "CI/CD Demo Running", "version": "abc12345" }
```

---

## Prerequisites

- AWS EC2 instance (Ubuntu 22.04 recommended)
- Docker Hub account
- GitHub repository with Actions enabled

---

## EC2 setup

Run this once on a fresh EC2 instance to install Docker and prepare the server:

```bash
curl -sO https://raw.githubusercontent.com/YOUR_USERNAME/ci-cd-demo/main/scripts/ec2_setup.sh
chmod +x ec2_setup.sh && bash ec2_setup.sh
```

Then log out and back in for the Docker group to take effect:

```bash
newgrp docker
```

Make sure port `3000` is open in your EC2 security group (inbound TCP).

---

## GitHub Secrets

Add these in your repo under **Settings → Secrets and variables → Actions**:

| Secret              | Description                              |
|---------------------|------------------------------------------|
| `DOCKERHUB_USERNAME`| Your Docker Hub username                 |
| `DOCKERHUB_TOKEN`   | Docker Hub access token (not password)   |
| `EC2_HOST`          | Public IP or DNS of your EC2 instance    |
| `EC2_USER`          | SSH username (e.g. `ubuntu`)             |
| `EC2_SSH_KEY`       | Private SSH key contents (PEM format)    |

To generate a Docker Hub token: Docker Hub → Account Settings → Security → New Access Token.

---

## Pipeline details

### Job 1 — Test

- Installs dependencies with `npm ci`
- Runs `jest --coverage`
- Uploads coverage report as a GitHub Actions artifact

### Job 2 — Build & Push

- Generates an 8-character image tag from the commit SHA (e.g. `f2ead7ee`)
- Builds the Docker image from `./app`
- Pushes two tags to Docker Hub:
  - `your-username/cicd-demo:f2ead7ee` (immutable, per-commit)
  - `your-username/cicd-demo:latest`

### Job 3 — Deploy + Auto Rollback

- Copies deployment scripts to EC2 via SCP
- SSHes into EC2 and runs `deploy_ec2.sh` which:
  1. Captures the currently running image as the stable fallback
  2. Pulls the new image
  3. Stops and removes the old container (including any container holding the port)
  4. Starts the new container with `--restart unless-stopped`
  5. Runs up to 10 health checks against `/health` with 10s intervals
  6. On success — exits cleanly
  7. On failure — stops the new container and restarts the stable image (rollback)

---

## Local development

```bash
cd app
npm install
npm test        # run tests
npm start       # start server on port 3000
```

Or with Docker Compose:

```bash
docker compose up
```

---

## Deploy log

Each deployment appends to `~/cicd-demo/deploy.log` on the EC2 instance:

```bash
tail -f ~/cicd-demo/deploy.log
```

---

## Image tagging strategy

| Tag        | When created        | Purpose                  |
|------------|---------------------|--------------------------|
| `f2ead7ee` | Every push to main  | Immutable, traceable     |
| `latest`   | Every push to main  | Convenience / local use  |

Rollback always uses the previously running image tag, not `latest`, so it's always deterministic.
