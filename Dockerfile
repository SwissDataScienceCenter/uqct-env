ARG BASE_IMAGE="nvidia/cuda:12.4.0-base-ubuntu22.04"
FROM ${BASE_IMAGE}

ARG USER="user"
ENV USER=$USER

ARG ENV_NAME="env"
ENV ENV_NAME=$ENV_NAME

USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl gcc git git-lfs htop libgl1 libglib2.0-0 ncdu openssh-client openssh-server psmisc rsync screen sudo tmux unzip vim wget nano && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* 

# install powerline-go (detect architecture at build time)
ARG POWERLINE_GO_VERSION=1.25
RUN set -eu; \
    uname_arch="$(uname -m)"; \
    case "${uname_arch}" in \
      x86_64) arch=amd64 ;; \
      aarch64|arm64) arch=arm64 ;; \
      *) echo "Unsupported arch: ${uname_arch}" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/justjanne/powerline-go/releases/download/v${POWERLINE_GO_VERSION}/powerline-go-linux-${arch}"; \
    curl -fsSL "${url}" -o /usr/local/bin/powerline-go; \
    chmod a+x /usr/local/bin/powerline-go
    
# install Miniforge (conda-forge bootstrap) + mamba
RUN set -eux; \
    arch="$(uname -m)" && \
    url="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-${arch}.sh" && \
    wget -O /tmp/miniforge.sh "${url}" && \
    bash /tmp/miniforge.sh -b -p /opt/conda && \
    rm /tmp/miniforge.sh && \
    /opt/conda/bin/conda config --system --set channel_priority strict && \
    /opt/conda/bin/conda install -y mamba pip pipx -n base -c conda-forge && \
    /opt/conda/bin/conda clean -y --all && \
    /opt/conda/bin/pipx ensurepath && \
    /opt/conda/bin/pipx install poetry uv

# handle the USER setup
RUN id -u ${USER} || useradd -s /bin/bash ${USER} && usermod -a -G ${USER} ${USER} && usermod -a -G users ${USER}

# passwordless sudo
RUN echo "${USER} ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Prepare user-owned SSH layout and host keys
# Generate host keys as root, then copy into a user-owned tree
RUN mkdir -p /home/user/.ssh /home/user/run /home/user/etc/ssh && \
    ssh-keygen -A && \
    cp /etc/ssh/ssh_host_* /home/user/etc/ssh/ && \
    chown -R user:user /home/user && \
    chmod 700 /home/user/.ssh /home/user/run /home/user/etc/ssh && \
    chmod 600 /home/user/etc/ssh/ssh_host_* || true

# Configure OpenSSH
RUN \
    printf '%s\n' \
        'Port 2222' \
        'PidFile /home/user/run/sshd.pid' \
        'PasswordAuthentication no' \
        'KbdInteractiveAuthentication no' \
        'ChallengeResponseAuthentication no' \
        'UsePAM no' \
        'PermitRootLogin no' \
        'PubkeyAuthentication yes' \
        'AllowTcpForwarding yes' \
        'AllowAgentForwarding yes' \
        'AuthorizedKeysFile .ssh/authorized_keys /myhome/.ssh/authorized_keys' \
        'HostKey /home/user/etc/ssh/ssh_host_rsa_key' \
        'HostKey /home/user/etc/ssh/ssh_host_ed25519_key' \
    > /home/user/sshd_config && \
    chown user:user /home/user/sshd_config && \
    chmod 600 /home/user/sshd_config

# copy start_sshd.sh
RUN cat > /home/${USER}/start_sshd.sh <<'EOF'
#!/bin/bash
unset LD_LIBRARY_PATH
exec /usr/sbin/sshd -D -e -f /home/${USER}/sshd_config
EOF
RUN chmod +x /home/${USER}/start_sshd.sh && \
    chown ${USER}:${USER} /home/${USER}/start_sshd.sh


# create workspace
RUN mkdir -p /home/${USER}/workspace
WORKDIR /home/${USER}/workspace

# copy environment.yml into /workspace
COPY environment.yml /workspace/${USER}/environment.yml

RUN /opt/conda/bin/mamba env create -f /workspace/${USER}/environment.yml -n ${ENV_NAME} && \
/opt/conda/bin/mamba clean -y --all

# startup configuration
USER ${USER}

# activate conda base environment and create Python venv with system site packages
RUN /bin/bash -c "source /opt/conda/etc/profile.d/conda.sh && conda activate ${ENV_NAME} && python -m venv --system-site-packages /home/${USER}/.venv/${ENV_NAME}"
RUN echo "source /home/${USER}/.venv/${ENV_NAME}/bin/activate" >> /home/${USER}/.bashrc

ENTRYPOINT /bin/bash
