#!/bin/bash 

set -o pipefail

# Environment variables
export DEBIAN_FRONTEND=noninteractive
export WORKDIR=/opt
# Default AUTO_INSTALL to false, but check for automated environments
export AUTO_INSTALL=${AUTO_INSTALL:-false}

# Detect if running in an automated environment (CI/CD)
if [ -n "${CI}" ] || [ -n "${GITHUB_ACTIONS}" ] || [ -n "${JENKINS_URL}" ] || [ -n "${TRAVIS}" ] || [ -n "${GITLAB_CI}" ]; then
    export AUTO_INSTALL=true
    echo "Detected automated environment, setting AUTO_INSTALL=true"
fi

# Check if the user is root
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root"
    exit 1
fi

# Function to compare version strings
compare_versions() {
    # Usage: compare_versions "version1" "version2"
    # Returns: 0 if version1 >= version2, 1 otherwise
    
    if [[ "$1" == "$2" ]]; then
        return 0
    fi
    
    local IFS=.
    local i ver1=("${1}") ver2=("${2}")
    
    # Fill empty fields with zeros
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do
        ver1[i]=0
    done
    
    for ((i=0; i<${#ver1[@]}; i++)); do
        if [[ -z ${ver2[i]} ]]; then
            ver2[i]=0
        fi
        
        if ((10#${ver1[i]} > 10#${ver2[i]})); then
            return 0
        fi
        
        if ((10#${ver1[i]} < 10#${ver2[i]})); then
            return 1
        fi
    done
    
    return 0
}

# Check Ubuntu version and architecture
check_system_requirements() {
    # Check if running on Ubuntu
    if [ ! -f /etc/lsb-release ] || ! grep -q "Ubuntu" /etc/lsb-release; then
        echo "Error: This script requires Ubuntu operating system"
        exit 1
    fi
    
    # Get Ubuntu version
    ubuntu_version=$(lsb_release -rs)
    
    # Extract major and minor version
    ubuntu_major_version=$(echo "${ubuntu_version}" | cut -d. -f1)
    ubuntu_minor_version=$(echo "${ubuntu_version}" | cut -d. -f2)
    
    # Check if version is between 20.04 and 22.04
    if [[ "${ubuntu_major_version}" -lt 20 ]] || \
       [[ "${ubuntu_major_version}" -eq 20 && "${ubuntu_minor_version}" -lt 4 ]] || \
       [[ "${ubuntu_major_version}" -gt 22 ]] || \
       [[ "${ubuntu_major_version}" -eq 22 && "${ubuntu_minor_version}" -gt 4 ]]; then
        echo "Error: This script requires Ubuntu version between 20.04 and 22.04 (current: ${ubuntu_version})"
        exit 1
    fi
    
    # Check architecture
    arch=$(uname -m)
    if [ "${arch}" != "x86_64" ]; then
        echo "Error: This script requires x86_64 architecture (current: ${arch})"
        exit 1
    fi
    
    # Check Nginx version
    if command -v nginx &>/dev/null; then
        nginx_version="$(nginx -v 2>&1 | grep -o '[0-9.]*$')"
        required_version="1.21.5"
        
        if ! compare_versions "${nginx_version}" "${required_version}"; then
            echo "Error: This script requires Nginx version >= ${required_version} (current: ${nginx_version})"
            exit 1
        fi
        
        echo "Nginx version check passed: ${nginx_version}"
    else
        echo "Nginx not installed yet. Latest version will be installed"
    fi
    
    echo "System check passed: Ubuntu ${ubuntu_version} on ${arch} architecture"
}

install_dependencies() {
    apt-get update -y && apt-get upgrade -y
    apt-get install -y apt-utils autoconf automake build-essential git libcurl4-openssl-dev libgeoip-dev liblmdb-dev libpcre3-dev libssl-dev libtool libxml2-dev libyajl-dev pkgconf wget zlib1g-dev software-properties-common
}

install_modsecurity() {
    git clone https://github.com/owasp-modsecurity/ModSecurity.git "${WORKDIR}/ModSecurity"
    cd "${WORKDIR}/ModSecurity" || exit

    git submodule init
    git submodule update

    ./build.sh
    ./configure

    make
    make install

    # Install ModSecurity-nginx Connector
    git clone https://github.com/owasp-modsecurity/ModSecurity-nginx.git "${WORKDIR}/ModSecurity-nginx"
}

install_nginx_with_modsecurity() {
    nginx_version=""
    required_version="1.21.5"
    should_install=false
    
    # Check if nginx is already installed
    if command -v nginx &>/dev/null; then
        current_version="$(nginx -v 2>&1 | grep -o '[0-9.]*$')"
        
        if compare_versions "${current_version}" "${required_version}"; then
            echo "Using existing Nginx version: ${current_version}"
            nginx_version="${current_version}"
        else
            echo "Existing Nginx version ${current_version} does not meet minimum requirements (>= ${required_version})"
            
            if [ "${AUTO_INSTALL}" = "true" ]; then
                echo "AUTO_INSTALL is enabled. Will install the latest version."
                should_install=true
            else
                read -p "Would you like to install the latest version? (y/n): " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    should_install=true
                else
                    echo "Exiting as Nginx version requirements are not met."
                    exit 1
                fi
            fi
        fi
    else
        echo "Nginx is not installed"
        
        if [ "${AUTO_INSTALL}" = "true" ]; then
            echo "AUTO_INSTALL is enabled. Will install the latest version."
            should_install=true
        else
            read -p "Would you like to install the latest version? (y/n): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                should_install=true
            else
                echo "Exiting as Nginx is required but not installed."
                exit 1
            fi
        fi
    fi
    
    # Install nginx if needed
    if [ "${should_install}" = "true" ]; then
        echo "Installing latest Nginx version..."
        add-apt-repository ppa:ondrej/nginx -y || { echo "Failed to add PPA"; exit 1; }
        apt update
        apt install nginx -y
        systemctl enable nginx
        systemctl status nginx
        nginx_version="$(nginx -v 2>&1 | grep -o '[0-9.]*$')"
        
        # Verify the installed version meets requirements
        if ! compare_versions "${nginx_version}" "${required_version}"; then
            echo "Error: The installed Nginx version ${nginx_version} does not meet minimum requirements (>= ${required_version})"
            exit 1
        fi
        
        echo "Successfully installed Nginx version: ${nginx_version}"
    fi
    
    # At this point, nginx_version should be set and satisfies requirements
    echo "Proceeding with Nginx version: ${nginx_version}"
    
    cd "${WORKDIR}" && wget "https://nginx.org/download/nginx-${nginx_version}.tar.gz"
    tar -xzvf "${WORKDIR}/nginx-${nginx_version}.tar.gz"

    cd "${WORKDIR}/nginx-${nginx_version}" || exit

    # Build nginx with ModSecurity module
    ./configure --with-compat --add-dynamic-module="${WORKDIR}/ModSecurity-nginx"
    make
    make modules

    # Copy modules and configuration files
    cp objs/ngx_http_modsecurity_module.so /etc/nginx/modules-enabled/
    cp "${WORKDIR}/ModSecurity/modsecurity.conf-recommended" /etc/nginx/modsecurity.conf
    cp "${WORKDIR}/ModSecurity/unicode.mapping" /etc/nginx/unicode.mapping
}

install_owasp_crs() {
    echo "Installing OWASP CoreRuleSet..."
    
    # Clone the CoreRuleSet repository
    git clone https://github.com/coreruleset/coreruleset.git /etc/nginx/owasp-crs
    
    # Copy the example configuration
    cp /etc/nginx/owasp-crs/crs-setup.conf{.example,}
    
    # Update modsecurity.conf to include the CRS rules
    echo "Updating ModSecurity configuration to load OWASP CRS..."
    
    # Append CRS configuration to modsecurity.conf if not already there
    if ! grep -q "Include owasp-crs/crs-setup.conf" /etc/nginx/modsecurity.conf; then
        # Add a blank line if the file doesn't end with one
        [[ $(tail -c 1 /etc/nginx/modsecurity.conf) != "" ]] && echo "" >> /etc/nginx/modsecurity.conf
        
        # Append the CRS configuration
        cat >> /etc/nginx/modsecurity.conf << EOF
# OWASP CRS Configuration
Include owasp-crs/crs-setup.conf
Include owasp-crs/rules/*.conf
EOF
    else
        echo "OWASP CRS configuration already exists in modsecurity.conf"
    fi
    
    # Test Nginx configuration
    echo "Testing Nginx configuration..."
    if nginx -t; then
        echo "Nginx configuration test successful"
        
        # Restart Nginx
        echo "Restarting Nginx service..."
        service nginx restart
        
        echo "OWASP CoreRuleSet installation and configuration completed successfully"
    else
        echo "Error: Nginx configuration test failed. Please check your configuration."
        exit 1
    fi
}


main() {
    check_system_requirements
   install_dependencies
   install_modsecurity
   install_nginx_with_modsecurity
   install_owasp_crs
}

main