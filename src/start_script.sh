#!/usr/bin/env bash

# Determine which branch to clone based on environment variables
BRANCH="master" # Default branch

if [ "$is_dev" == "true" ]; then
    BRANCH="experimental"
    echo "Development mode enabled. Cloning experimental branch..."
elif [ -n "$git_branch" ]; then
    BRANCH="$git_branch"
    echo "Custom branch specified: $git_branch"
else
    echo "Using default branch: master"
fi

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

echo "Waiting for internet connectivity..."
MAX_RETRIES=30
RETRY_COUNT=0

while ! getent hosts github.com > /dev/null; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
        echo "Error: DNS resolution for github.com failed after $MAX_RETRIES seconds."
        exit 1
    fi
    sleep 1
done

echo "Network is up! Proceeding with clone..."

# Clean up any previous failed attempts
rm -rf /tmp/comfyui-wan
# Clone the repository to a temporary location with the specified branch
echo "Cloning branch '$BRANCH' from repository..."
git clone --branch "$BRANCH" https://github.com/concreteshoes/comfyui-wan.git /tmp/comfyui-wan

# Check if clone was successful
if [ $? -ne 0 ]; then
    echo "Error: Failed to clone branch '$BRANCH'. Falling back to main branch..."
    git clone https://github.com/concreteshoes/comfyui-wan.git /tmp/comfyui-wan

    if [ $? -ne 0 ]; then
        echo "Error: Failed to clone repository. Exiting..."
        exit 1
    fi
fi

# Move start.sh to root and execute it
mv /tmp/comfyui-wan/src/start.sh /
chmod +x /start.sh
exec /start.sh
