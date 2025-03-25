#!/bin/bash

set -o pipefail


# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Setup logging
LOG_FILE="/tmp/modsecurity_install_$(date +%Y%m%d_%H%M%S).log"
touch "${LOG_FILE}"

# Logging function
log() {
    local level="$1"
    local message="$2"
    local color="${NC}"
    
    # Set color based on log level
    case "${level}" in
        "INFO") color="${GREEN}" ;;
        "WARN") color="${YELLOW}" ;;
        "ERROR") color="${RED}" ;;
        "DEBUG") color="${BLUE}" ;;
        *) color="${NC}" ;;
    esac
    
    # Log to console with color
    echo -e "${color}[${level}] ${message}${NC}"
    
    # Log to file without color codes
    echo "[$(date '+%Y-%m-%d %H:%M')] [${level}] ${message}" >> "${LOG_FILE}"
}

# Function to execute command with error handling
execute_command() {
    local cmd="$1"
    local error_msg="$2"
    local output
    
    log "DEBUG" "Executing: ${cmd}"
    output=$(eval "${cmd}" 2>&1)
    local status=$?
    
    if [[ "${status}" -ne 0 ]]; then
        log "ERROR" "${error_msg}"
        log "ERROR" "Command output: ${output}"
        log "ERROR" "Command failed with status ${status}. Check log: ${LOG_FILE}"
        exit 1
    else
        log "DEBUG" "Command executed successfully"
        return 0
    fi
}

# Environment variables
export DEBIAN_FRONTEND=noninteractive
export WORKDIR=/opt
# Default AUTO_INSTALL to false, but check for automated environments
export AUTO_INSTALL=${AUTO_INSTALL:-false}
# Default KEEP_BUILD_FILES to false
export KEEP_BUILD_FILES=${KEEP_BUILD_FILES:-false}

# Detect if running in an automated environment (CI/CD)
if [[ -n "${CI}" ]] || [[ -n "${GITHUB_ACTIONS}" ]] || [[ -n "${JENKINS_URL}" ]] || [[ -n "${TRAVIS}" ]] || [[ -n "${GITLAB_CI}" ]]; then
    export AUTO_INSTALL=true
    log "INFO" "Detected automated environment, setting AUTO_INSTALL=true"
fi

# Check if the user is root
if [[ "$(id -u)" -ne 0 ]]; then
    log "ERROR" "This script must be run as root"
    exit 1
fi

# Function to compare version strings
compare_versions() {
    command -v dc &>/dev/null || apt update && apt install -y dc
    # Usage: compare_versions "${current_version}" "${required_version}"
    # Returns: 0 if current_version < required_version, 1 otherwise
    local v1="$1"
    local v2="$2"

    echo "${v1}<${v2}" | dc
}

# Check Ubuntu version and architecture
check_system_requirements() {
    # Check if running on Ubuntu
    if [[ ! -f /etc/lsb-release ]] || ! grep -q "Ubuntu" /etc/lsb-release; then
        log "ERROR" "This script requires Ubuntu operating system"
        exit 1
    fi
    
    # Get Ubuntu version
    ubuntu_version=$(grep "DISTRIB_RELEASE" /etc/lsb-release | cut -d= -f2)
    
    # Extract major and minor version
    ubuntu_major_version=$(echo "${ubuntu_version}" | cut -d. -f1)
    ubuntu_minor_version=$(echo "${ubuntu_version}" | cut -d. -f2)
    
    # Check if version is between 20.04 and 22.04
    if [[ "${ubuntu_major_version}" -lt 20 ]] || \
       [[ "${ubuntu_major_version}" -eq 20 && "${ubuntu_minor_version}" -lt 4 ]] || \
       [[ "${ubuntu_major_version}" -gt 22 ]] || \
       [[ "${ubuntu_major_version}" -eq 22 && "${ubuntu_minor_version}" -gt 4 ]]; then
        log "ERROR" "This script requires Ubuntu version between 20.04 and 22.04 (current: ${ubuntu_version})"
        exit 1
    fi
    
    # Check architecture
    arch=$(uname -m)
    if [[ "${arch}" != "x86_64" ]]; then
        log "ERROR" "This script requires x86_64 architecture (current: ${arch})"
        exit 1
    fi
    
    # Check Nginx version
    if command -v nginx &>/dev/null; then
        nginx_version="$(nginx -v 2>&1 | grep -o '[0-9.]*$')"
        required_version="1.21.5"
        
        if ! compare_versions "${nginx_version}" "${required_version}"; then
            log "ERROR" "This script requires Nginx version >= ${required_version} (current: ${nginx_version})"
            exit 1
        fi
        
        log "INFO" "Nginx version check passed: ${nginx_version}"
    else
        log "INFO" "Nginx not installed yet. Latest version will be installed"
    fi
    
    log "INFO" "System check passed: Ubuntu ${ubuntu_version} on ${arch} architecture"
}

install_dependencies() {
    log "INFO" "Installing dependencies..."
    apt-get update -y && apt-get upgrade -y
    apt-get install -y apt-utils autoconf automake build-essential git libcurl4-openssl-dev libgeoip-dev liblmdb-dev libpcre3-dev libssl-dev libtool libxml2-dev libyajl-dev pkgconf wget zlib1g-dev software-properties-common g++ libpcre2-dev libpcre2-posix3
    log "INFO" "Dependencies installed successfully"
}

install_modsecurity() {
    log "INFO" "Installing ModSecurity..."
    git clone https://github.com/owasp-modsecurity/ModSecurity.git "${WORKDIR}/ModSecurity"
    cd "${WORKDIR}/ModSecurity" || exit

    execute_command "git submodule init" "Failed to initialize git submodules"
    execute_command "git submodule update" "Failed to update git submodules"

    execute_command "./build.sh" "Failed to execute build.sh for ModSecurity"
    execute_command "./configure" "Failed to configure ModSecurity"

    execute_command "make" "Failed to compile ModSecurity"
    execute_command "make install" "Failed to install ModSecurity"

    # Install ModSecurity-nginx Connector
    log "INFO" "Installing ModSecurity-nginx connector..."
    execute_command "git clone https://github.com/owasp-modsecurity/ModSecurity-nginx.git \"${WORKDIR}/ModSecurity-nginx\"" "Failed to clone ModSecurity-nginx repository"
    log "INFO" "ModSecurity installation completed"
}

install_nginx_with_modsecurity() {
    nginx_version=""
    required_version="1.21.5"
    should_install=false
    
    # Check if nginx is already installed
    if command -v nginx &>/dev/null; then
        current_version="$(nginx -v 2>&1 | grep -o '[0-9.]*$')"
        
        if compare_versions "${current_version}" "${required_version}"; then
            log "INFO" "Using existing Nginx version: ${current_version}"
            nginx_version="${current_version}"
        else
            log "WARN" "Existing Nginx version ${current_version} does not meet minimum requirements (>= ${required_version})"
            
            if [[ "${AUTO_INSTALL}" = "true" ]]; then
                log "INFO" "AUTO_INSTALL is enabled. Will install the latest version."
                should_install=true
            else
                read -p "Would you like to install the latest version? (y/n): " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    should_install=true
                else
                    log "ERROR" "Exiting as Nginx version requirements are not met."
                    exit 1
                fi
            fi
        fi
    else
        log "INFO" "Nginx is not installed"
        
        if [[ "${AUTO_INSTALL}" = "true" ]]; then
            log "INFO" "AUTO_INSTALL is enabled. Will install the latest version."
            should_install=true
        else
            read -p "Would you like to install the latest version? (y/n): " -n 1 -r
            echo
            if [[ ${REPLY} =~ ^[Yy]$ ]]; then
                should_install=true
            else
                log "ERROR" "Exiting as Nginx is required but not installed."
                exit 1
            fi
        fi
    fi
    
    # Install nginx if needed
    if [[ "${should_install}" = "true" ]]; then
        log "INFO" "Installing latest Nginx version..."
        add-apt-repository ppa:ondrej/nginx -y || { log "ERROR" "Failed to add PPA"; exit 1; }
        apt update
        apt install nginx -y
        systemctl enable nginx
        systemctl status nginx
        nginx_version="$(nginx -v 2>&1 | grep -o '[0-9.]*$')"
        
        # Verify the installed version meets requirements
        if ! compare_versions "${nginx_version}" "${required_version}"; then
            log "ERROR" "The installed Nginx version ${nginx_version} does not meet minimum requirements (>= ${required_version})"
            exit 1
        fi
        
        log "INFO" "Successfully installed Nginx version: ${nginx_version}"
    fi
    
    # At this point, nginx_version should be set and satisfies requirements
    log "INFO" "Proceeding with Nginx version: ${nginx_version}"
    
    execute_command "cd \"${WORKDIR}\" && wget \"https://nginx.org/download/nginx-${nginx_version}.tar.gz\"" "Failed to download Nginx source"
    execute_command "cd \"${WORKDIR}\" && tar -xzvf \"${WORKDIR}/nginx-${nginx_version}.tar.gz\"" "Failed to extract Nginx source"

    cd "${WORKDIR}/nginx-${nginx_version}" || { log "ERROR" "Failed to change directory to Nginx source"; exit 1; }

    # Build nginx with ModSecurity module
    execute_command "./configure --with-compat --add-dynamic-module=\"${WORKDIR}/ModSecurity-nginx\"" "Failed to configure Nginx with ModSecurity"
    execute_command "make" "Failed to compile Nginx"
    execute_command "make modules" "Failed to compile Nginx modules"

    # Copy modules and configuration files
    execute_command "cp objs/ngx_http_modsecurity_module.so /etc/nginx/modules-enabled/" "Failed to copy ModSecurity module to Nginx modules directory"
    execute_command "cp \"${WORKDIR}/ModSecurity/modsecurity.conf-recommended\" /etc/nginx/modsecurity.conf" "Failed to copy ModSecurity configuration"
    execute_command "cp \"${WORKDIR}/ModSecurity/unicode.mapping\" /etc/nginx/unicode.mapping" "Failed to copy unicode mapping file"
}

install_owasp_crs() {
    log "INFO" "Installing OWASP CoreRuleSet..."
    
    # Clone the CoreRuleSet repository
    execute_command "git clone https://github.com/coreruleset/coreruleset.git /etc/nginx/owasp-crs" "Failed to clone OWASP CoreRuleSet repository"
    
    # Copy the example configuration
    execute_command "cp /etc/nginx/owasp-crs/crs-setup.conf{.example,}" "Failed to copy CRS setup configuration"
    
    # Update modsecurity.conf to include the CRS rules
    log "INFO" "Updating ModSecurity configuration to load OWASP CRS..."
    
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
        log "WARN" "OWASP CRS configuration already exists in modsecurity.conf"
    fi
    
    # Test Nginx configuration
    log "INFO" "Testing Nginx configuration..."
    if nginx -t; then
        log "INFO" "Nginx configuration test successful"
        
        # Restart Nginx
        log "INFO" "Restarting Nginx service..."
        execute_command "service nginx restart" "Failed to restart Nginx service"
        
        log "INFO" "OWASP CoreRuleSet installation and configuration completed successfully"
    else
        log "ERROR" "Nginx configuration test failed. Please check your configuration."
        exit 1
    fi
}

cleanup() {
    log "INFO" "Starting cleanup process..."
    
    # Only clean build files if KEEP_BUILD_FILES is not true
    if [[ "${KEEP_BUILD_FILES}" != "true" ]]; then
        log "INFO" "Removing build files..."
        
        # Files to remove
        local files_to_remove=(
            "${WORKDIR}/nginx-*.tar.gz"
            "${WORKDIR}/ModSecurity"
            "${WORKDIR}/ModSecurity-nginx"
            "${WORKDIR}/nginx-*"
        )
        
        for file in "${files_to_remove[@]}"; do
            if ls "${file}" 1> /dev/null 2>&1; then
                execute_command "rm -rf \"${file}\"" "Failed to remove \"${file}\""
            else
                log "DEBUG" "File/directory not found: \"${file}\""
            fi
        done
        
        log "INFO" "Build files removed successfully"
    else
        log "INFO" "Skipping build file cleanup as KEEP_BUILD_FILES=true"
    fi
    
    # Clean apt cache
    log "INFO" "Cleaning apt cache..."
    execute_command "apt-get clean" "Failed to clean apt cache"
    execute_command "apt-get autoremove -y" "Failed to autoremove packages"
    
    log "INFO" "Cleanup completed successfully"
}

main() {
    log "INFO" "Starting ModSecurity v3 installation"
    log "INFO" "Log file: \"${LOG_FILE}\""
    
    # Display configuration
    log "INFO" "Configuration:"
    log "INFO" "- WORKDIR: \"${WORKDIR}\""
    log "INFO" "- AUTO_INSTALL: \"${AUTO_INSTALL}\""
    log "INFO" "- KEEP_BUILD_FILES: \"${KEEP_BUILD_FILES}\""
    
    check_system_requirements
    install_dependencies
    install_modsecurity
    install_nginx_with_modsecurity
    install_owasp_crs
    
    # Perform cleanup
    cleanup
    
    log "INFO" "ModSecurity v3 installation completed successfully"
}

main
