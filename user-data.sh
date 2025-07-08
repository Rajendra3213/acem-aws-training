#!/bin/bash

# Update and install required packages
apt-get update -y
apt-get install -y curl python3

# Create web root directory
mkdir -p /var/www/html

# Fetch instance metadata from IMDS
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
AVAIL_ZONE=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)

# Create HTML file with metadata
cat <<EOF > /var/www/html/index.html
<html>
  <head><title>EC2 Metadata</title></head>
  <body>
    <h1>EC2 Instance Metadata (Ubuntu)</h1>
    <p><strong>Instance ID:</strong> $INSTANCE_ID</p>
    <p><strong>Availability Zone:</strong> $AVAIL_ZONE</p>
  </body>
</html>
EOF

# Start a simple HTTP server on port 80
cd /var/www/html
nohup python3 -m http.server 80 &
