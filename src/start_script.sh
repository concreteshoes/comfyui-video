#!/usr/bin/env bash

git clone https://github.com/concreteshoes/comfyui-wan.git

# Export environment variables
extract_env() {
    local pattern="$1"

    mkdir -p /etc/profile.d
    : > /etc/profile.d/container_env.sh

    echo "=== Searching for env source ==="

    local env_file=""
    for pid in /proc/[0-9]*; do
        if tr '\0' '\n' < "$pid/environ" 2> /dev/null | grep -E -q "DOWNLOAD_.*|USE_FP8_.*|CIVITAI_TOKEN|HUGGINGFACE_API_KEY|SSH_PUBLIC_KEY"; then
            env_file="$pid/environ"
            echo "Using env from $pid"
            break
        fi
    done

    if [ -z "$env_file" ]; then
        echo "No env source found!"
        return
    fi

    while IFS='=' read -r key value; do
        if [[ "$key" =~ ^($pattern)$ ]]; then
            echo "Exporting: $key"

            export "$key=$value"
            printf 'export %s=%q\n' "$key" "$value" >> /etc/profile.d/container_env.sh
        fi
    done < <(tr '\0' '\n' < "$env_file")

    chmod +x /etc/profile.d/container_env.sh
}

extract_env "DOWNLOAD_.*|USE_FP8_.*|CIVITAI_TOKEN|HUGGINGFACE_API_KEY|SSH_PUBLIC_KEY"
chmod +x /etc/profile.d/container_env.sh

mv comfyui-wan/src/start.sh /
exec /start.sh
