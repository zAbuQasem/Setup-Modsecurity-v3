# ModSecurity v3 Setup for Nginx

## Navigation
- [Overview](#overview)
- [Requirements](#requirements)
- [Usage](#usage)
- [Configuration Options](#configuration-options)
- [What the Script Does](#what-the-script-does)
- [Post Installation](#post-installation)
- [Troubleshooting](#troubleshooting)
- [Security Considerations](#security-considerations)
- [Contributing](#contributing)

## Overview

The `setup-modsec.sh` script installs and configures:
- ModSecurity v3 (from source)
- Nginx with ModSecurity connector
- OWASP Core Rule Set (CRS)

## Requirements

- Ubuntu 20.04 to 22.04 LTS
- x86_64 architecture
- Root privileges
- Nginx version 1.21.5 or higher (will be installed if not present)

> **Note**: This script has been tested only on Ubuntu 20.04 and 22.04 LTS. Other Ubuntu versions or Linux distributions may not work correctly.

## Usage

1. Clone the repository:
   ```bash
   git clone https://github.com/zAbuQasem/Setup-Modsecurity-v3.git
   cd Setup-Modsecurity-v3
   ```

2. Run the script with root user:
   ```bash
   sudo ./setup-modsec.sh
   ```

## Configuration Options

The script supports the following environment variables:

- `AUTO_INSTALL`: Set to `false` (default). Set to `true` for automated installation without prompts.

Example with custom configuration:
```bash
sudo AUTO_INSTALL=true ./setup-modsec.sh
```

## What the Script Does

1. Checks system requirements (Ubuntu version, architecture, Nginx version)
2. Installs necessary dependencies
3. Compiles ModSecurity v3 from source
4. Installs or configures Nginx with ModSecurity connector
5. Installs and configures OWASP Core Rule Set

## Post Installation

After running the script, you need to enable ModSecurity in your Nginx configuration:

1. Edit the Nginx main configuration to load the ModSecurity module:
   ```bash
   sudo nano /etc/nginx/nginx.conf
   ```
   Add this line at the beginning of the file:
   ```
   load_module /etc/nginx/modules-enabled/ngx_http_modsecurity_module.so;
   ```

2. Modify your server block to activate ModSecurity:
   ```bash
   sudo nano /etc/nginx/sites-enabled/default
   ```
   Add these lines inside the server block:
   ```
   modsecurity on;
   modsecurity_rules_file /etc/nginx/modsecurity.conf;
   ```

3. Enable the ModSecurity rule engine:
   ```bash
   sudo nano /etc/nginx/modsecurity.conf
   ```
   Change `SecRuleEngine DetectionOnly` to:
   ```
   SecRuleEngine On
   ```

4. Test and restart Nginx:
   ```bash
   sudo nginx -t
   sudo systemctl restart nginx
   ```

### Testing ModSecurity
If the response returns a `403 Forbidden` status, it indicates that ModSecurity is functioning as expected.

```bash
curl http://localhost --data "testparam=<script>alert(1)</script>"
```

## Troubleshooting

If you encounter issues:

1. Check the script output for error messages
2. Verify your system meets the requirements
3. Ensure Nginx configuration is correct: `nginx -t`
4. Check ModSecurity logs for rule violations
   ```sh
      sudo tail -f /var/log/modsec_audit.log
   ```


## Security Considerations

- The script installs ModSecurity in detection mode by default
- Review and customize the rule set according to your security needs
- Regularly update the Core Rule Set to protect against new vulnerabilities


## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
