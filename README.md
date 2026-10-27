# setup-devops-al2.sh

Sets up an Amazon Linux 2 workspace with the Progress Rail DevOps tools: AWS CLI v2 + SSO profiles, SSM plugin, CodeCommit, Docker, kubectl, Helm, eksctl, Terraform (tfenv), Ansible, yq, and the Kafka CLI with MSK IAM auth.

## Run

```bash
chmod +x setup-devops-al2.sh
./setup-devops-al2.sh            # everything
./setup-devops-al2.sh --no-gui   # skip VS Code

Safe to re-run: anything already installed is skipped.

After install

source ~/.bashrc    # load PATH and helpers
prlogin             # AWS SSO login
prenv test          # switch account: dev | test | staging | prod | tools

Log out and back in to use docker without sudo.

Helpers

┌────────────────────────────────────────────┬──────────────────────────────────────────────────┐
│                  Command                   │                   What it does                   │
├────────────────────────────────────────────┼──────────────────────────────────────────────────┤
│ prlogin                                    │ aws sso login --sso-session progressrail         │
├────────────────────────────────────────────┼──────────────────────────────────────────────────┤
│ prenv <env>                                │ sets AWS_PROFILE and prints the current identity │
├────────────────────────────────────────────┼──────────────────────────────────────────────────┤
│ kt --bootstrap-server <broker>:9098 --list │ Kafka topics with IAM auth                       │
└────────────────────────────────────────────┴──────────────────────────────────────────────────┘

Versions

Pinned at the top of the script: TERRAFORM_VERSION, KAFKA_VERSION, MSK_IAM_AUTH_VERSION.
```
