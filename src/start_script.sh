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
    # 1. Unified pattern matching your template's specific variables
    local pattern="^(DOWNLOAD_.*|CIVITAI_TOKEN|HUGGINGFACE_API_KEY|FB_PASSWORD|.*_TO_DOWNLOAD|SSH_PUBLIC_KEY)$"
    local search_pattern="DOWNLOAD_.*|CIVITAI_TOKEN|HUGGINGFACE_API_KEY|FB_PASSWORD|.*_TO_DOWNLOAD|SSH_PUBLIC_KEY"

    mkdir -p /etc/profile.d
    : > /etc/profile.d/container_env.sh

    echo "=== Searching for env source ==="

    local env_file=""

    # Optimization: Target PID 1 (main container process) first to avoid race conditions
    if [ -r "/proc/1/environ" ] && tr '\0' '\n' < "/proc/1/environ" | grep -E -q "$search_pattern"; then
        env_file="/proc/1/environ"
        echo "Using env from PID 1"
    else
        # Fallback loop if PID 1 is restricted or missing variables
        for pid in /proc/[0-9]*; do
            if [ -r "$pid/environ" ] && [ "$pid" != "/proc/$$" ] && [ "$pid" != "/proc/1" ]; then
                if tr '\0' '\n' < "$pid/environ" 2> /dev/null | grep -E -q "$search_pattern"; then
                    env_file="$pid/environ"
                    echo "Using env from $pid"
                    break
                fi
            fi
        done
    fi

    if [ -z "$env_file" ] || [ ! -r "$env_file" ]; then
        echo "No valid env source found!"
        return 1
    fi

    # 2. Extract and securely parse variables
    while IFS= read -r line || [ -n "$line" ]; do
        [[ -z "$line" ]] && continue

        key="${line%%=*}"
        value="${line#*=}"

        if [[ "$key" =~ $pattern ]]; then
            echo "Exporting: $key"
            export "$key=$value"
            printf 'export %s=%q\n' "$key" "$value" >> /etc/profile.d/container_env.sh
        fi
    done < <(tr '\0' '\n' < "$env_file" 2> /dev/null)
}

extract_env

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

# Clean up any previous failed attempts safely inside /tmp
rm -rf /tmp/comfyui-video

# Clone the repository to a temporary location with the specified branch
echo "Cloning branch '$BRANCH' from repository..."
git clone --branch "$BRANCH" https://github.com/concreteshoes/comfyui-video.git /tmp/comfyui-video

# Check if clone was successful
if [ $? -ne 0 ]; then
    echo "Error: Failed to clone branch '$BRANCH'. Falling back to main branch..."
    git clone https://github.com/concreteshoes/comfyui-video.git /tmp/comfyui-video

    if [ $? -ne 0 ]; then
        echo "Error: Failed to clone repository. Exiting..."
        exit 1
    fi
fi

# Move start.sh to root and execute it
mv /tmp/comfyui-video/src/start.sh /
chmod +x /start.sh
exec /start.sh
