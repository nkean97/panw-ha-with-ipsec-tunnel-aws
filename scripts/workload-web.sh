#!/bin/bash
# Test web server for the workload instances (EC2 user_data at first boot).
#
# Serves a page on :80 with this instance's private IP, instance ID and AZ,
# read from IMDSv2 when the service starts. Uses only what ships with Amazon
# Linux 2023 (python3, curl), so it works before the firewalls pass traffic.
#
# To (re)install on a running instance:
#   aws ssm send-command --document-name AWS-RunShellScript \
#     --instance-ids <id> --parameters commands="$(cat scripts/workload-web.sh)"
set -euo pipefail

mkdir -p /opt/web /var/www

cat > /opt/web/render.sh <<'RENDER'
#!/bin/bash
set -euo pipefail
TOKEN=$(curl -sf -X PUT http://169.254.169.254/latest/api/token \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
md() { curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/$1"; }
IP=$(md local-ipv4)
ID=$(md instance-id)
AZ=$(md placement/availability-zone)
cat > /var/www/index.html <<HTML
<!doctype html>
<html><head><title>$IP</title></head>
<body style="font-family:sans-serif;margin:3em">
<h1>$IP</h1>
<p>instance $ID &middot; $AZ</p>
</body></html>
HTML
# Plain-text variant for scripts: curl http://<floating-ip>/ip
echo "$IP" > /var/www/ip
RENDER
chmod 755 /opt/web/render.sh

cat > /etc/systemd/system/web-test.service <<'UNIT'
[Unit]
Description=Test web server (shows instance IP from IMDS)
After=network-online.target
Wants=network-online.target

[Service]
ExecStartPre=/opt/web/render.sh
ExecStart=/usr/bin/python3 -m http.server 80 --directory /var/www
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable web-test.service
systemctl restart web-test.service
