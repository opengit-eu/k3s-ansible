#!/bin/bash

# Source kubeconfig path
SOURCE_KUBECONFIG="/home/bs/.kube/config"

# Target users
USERS=("name" "name" "name")

# Check if source kubeconfig exists
if [ ! -f "$SOURCE_KUBECONFIG" ]; then
    echo "Error: Source kubeconfig not found at $SOURCE_KUBECONFIG"
    exit 1
fi

# Loop through users and set up kubeconfig
for USER in "${USERS[@]}"; do
    echo "Setting up kubeconfig for user: $USER"
    
    # Create .kube directory if it doesn't exist
    sudo -u "$USER" mkdir -p "/home/$USER/.kube"
    
    # Copy kubeconfig file
    sudo cp "$SOURCE_KUBECONFIG" "/home/$USER/.kube/config"
    
    # Set ownership
    sudo chown "$USER:$USER" "/home/$USER/.kube/config"
    
    # Set permissions (read/write for owner only)
    sudo chmod 600 "/home/$USER/.kube/config"
    
    echo "✓ Kubeconfig set up for $USER"
done

echo "Done! Kubeconfig has been set up for all users."