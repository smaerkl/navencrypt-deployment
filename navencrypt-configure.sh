#!/bin/bash
#
# Navencrypt interactive configuration script. This assumes Navencrypt is already installed.
#
# Author:: Ross McDonald (<ross.mcdonald@gazzang.com>)
# Copyright 2014, Cloudera
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

password_file="/root/navencrypt-password"

function err {
    printf "\n\x1b[31mError:\x1b[0m $@\n"
    exit 1
}

function printBanner {
    color="\x1b[34m"
    company_color="\x1b[32m"
    echo -e "$color                          

 ______                                                      
|  ___ \                                                _    
| |   | | ____ _   _ ____ ____   ____  ____ _   _ ____ | |_  
| |   | |/ _  | | | / _  )  _ \ / ___)/ ___) | | |  _ \|  _) 
| |   | ( ( | |\ V ( (/ /| | | ( (___| |   | |_| | | | | |__ 
|_|   |_|\_||_| \_/ \____)_| |_|\____)_|    \__  | ||_/ \___)
                                           (____/|_|         
                                                    Powered by$company_color Cloudera\x1b[0m"
    echo ""
}

function createRandomPassword {
    test -f $password_file && return
    printf "- Creating a password file at '$password_file'. You'll want to change this once configuration is completed.\n"
    tr -dc A-Za-z0-9_ < /dev/urandom | head -c 30 | tee $password_file &>/dev/null
    chown root:root $password_file
    chmod 400 $password_file
    if [[ ! -f $password_file ]]; then
        err "Password file ($password_file) could not be created. Please make sure that directory exists."
    fi
}

function verifyConnectivity {
    printf "- Checking connectivity to the '$@' keystore.... "
    curl https://$@/?a=fingerprint &>/dev/null || err "Couldn't connect to keyserver. Check connectivity to '$@'."
    printf "connection valid.\n"
}

function displayNavencryptPartitions {
    printf "\n==================================================\n"
    printf "\nYou currently have the following mount points available:\n\n"
    cat /etc/navencrypt/ztab | awk '/^\// { print $1 }'
    printf "\n==================================================\n"
}

function registerClient {
    test -f /etc/navencrypt/keytrustee/clientname && printf "\n- Navencrypt is already registered. Skipping registration process.\n\n" && return
    printf "\n- What zTrustee Server would you like to register against? [ztdemo.gazzang.net]\n"
    read keyserver < /dev/tty
    test -z $keyserver && keyserver="ztdemo.gazzang.net"
    verifyConnectivity $keyserver

    test -z $org || printf "- What organization would you like to register against? []\n"
    test -z $org || read org < /dev/tty
    test -z $auth || printf "- What is the authorization code for the '$org' organization? []\n"
    test -z $auth || read auth < /dev/tty

    register_command="navencrypt register -s $keyserver -t single-passphrase"
    # Test for 0 length strings to maintain compatibility with classic reg mode
    test -z $org || register_command="$register_command -o $org"
    test -z $auth || register_command="$register_command --auth=$auth"

    printf "\n==================================================\n"
    printf "\nNote! This is the command we will be using to register Navencrypt:\n"
    printf "\n\$ $register_command\n"
    printf "\nPlease feel free to save this for future use.\n"
    printf "==================================================\n\n"

    printf "- Registering...\n" && printf "$(cat $password_file)\n$(cat $password_file)" | $register_command
    if [[ $? -ne 0 ]]; then
        err "Could not register with keyserver. Please check command output for more information."
    fi
    printf "\n"
}

function prepareClient {
    echo -e '\n- Do you need to prepare any drives/directories for encryption? [no]'
    read response < /dev/tty
    test "${response:0:1}" = "y" || test "${response:0:1}" = "Y" || return
    unset response

    echo '- Where would you like to store the encrypted data? [/var/lib/navencrypt/.private]'
    read storage < /dev/tty
    test -z $storage && storage="/var/lib/navencrypt/.private"
    grep "$storage" /etc/navencrypt/ztab &>/dev/null && err "The location '$storage' is already marked as an encrypted partition. Remove it before continuing."
    test -L $storage && storage="$(ls $storage | xargs readlink -f)" && echo "- You specified a symbolic link. Setting new storage target to '$storage'."
    test -b $storage && err "Sorry, block-level encryption is not support by this script (yet)."
    test -d $storage || mkdir -p $storage && echo "- Storage target created."

    echo '- Where would you like to mount the encrypted partition? [/var/lib/navencrypt/encrypted]'
    read mount < /dev/tty
    test -z $mount && mount="/var/lib/navencrypt/encrypted"
    grep "$mount" /etc/navencrypt/ztab &>/dev/null && err "The location '$mount' is already marked as an encrypted partition. Remove it before continuing."
    test -d $mount || mkdir -p $mount && echo "- Mount target created."

    echo '- What pass-through mount options would you like for the encrypted partition (e.g. noatime)? []'
    read mount_opt < /dev/tty
    test -z $mount_opt || mount_opt="-o $mount_opt"

    prepare_command="navencrypt-prepare $mount_opt $storage $mount"
    printf "\n==================================================\n"
    printf "\nNote! This is the command we will be using to prepare the partition:\n"
    printf "\n\$ $prepare_command\n"
    printf "\n==================================================\n"

    echo "- Creating encrypted partition..."
    cat $password_file | eval "$prepare_command"
    if [[ $? -ne 0 ]]; then
        err "Could not prepare directory. Please check command output for more information."
    fi
    echo ""
}

function encryptData {
    printf "\n- Do you want to encrypt any data? [no]\n"
    read response < /dev/tty
    test "${response:0:1}" = "y" || test "${response:0:1}" = "Y" || return
    unset response

    printf "- What directory would you like to encrypt?\n"
    read to_encrypt < /dev/tty
    test -z $to_encrypt && err "A valid directory or file location must be specified."
    test -L $to_encrypt && to_encrypt="$(ls $to_encrypt | xargs readlink -f)" && printf "- You specified a symbolic link. Setting new encryption target to '$to_encrypt'.\n"
    test -d $to_encrypt || test -f $to_encrypt || err "A valid directory or file location must be specified."

    if [[ -z $mount ]]; then
        displayNavencryptPartitions
        printf "- What mount location would you like to use to store this data in? []\n"
        read mount < /dev/tty
        test -z $mount && err "A valid encrypted partition must be specified."
    else
        printf "- You specified the mount location '$mount' from before. Would you like to use that location to store this encrypted data? [yes]\n"
        read response < /dev/tty
        test -z $response && response="yes"
        if [["${response:0:1}" = "n"] -o ["${response:0:1}" = "N"]]; then
            displayNavencryptPartitions
            printf "- What mount location would you like to use to store this data in? []\n"
            read mount < /dev/tty
            grep "$mount" /etc/navencrypt/ztab &>/dev/null || err "A valid encrypted partition must be specified."
        fi
        unset response
    fi
    test -z $mount && err "You need to specify a valid mount location."

    printf "- What category name would you like to encrypt this data with? [encrypted]\n"
    read category < /dev/tty
    test -z $category && category="encrypted"

    encrypt_command="navencrypt-move encrypt @$category $to_encrypt $mount"
    printf "\n==================================================\n"
    printf "\nNote! This is the command we will be using to encrypt:\n"
    printf "\n\$ $encrypt_command\n"
    printf "\n==================================================\n"

    printf "- Encrypting target data...\n"
    cat $password_file | eval "$encrypt_command"
    if [[ $? -ne 0 ]]; then
        err "Could not encrypt object '$to_encrypt'. Please check command output for more information."
    fi
    printf "\n"
}

function addRules {
    printf "\n- Do you want to set any ACL rules? [no]\n"
    read response < /dev/tty
    test "${response:0:1}" = "y" || test "${response:0:1}" = "Y" || return
    unset response

    printf "- What binary would you like to allow access to the encrypted data?\n"
    read binary < /dev/tty
    test -z $binary && err "Please specify a valid binary."

    test -L $binary && binary="$(ls $binary | xargs readlink -f)" && printf "- You specified a symbolic link. Setting new binary target to '$binary'.\n"
    test -x $binary || err "A valid executable must be specified."

    if [[ -z $category ]]; then
        printf "- What category name would you like to set for this rule? [encrypted]\n"
        read category < /dev/tty
        test -z $category && category="encrypted"
    else
        printf "- You used the category name '$category' before. Would you like to use the same name? [yes]\n"
        read response < /dev/tty
        test -z $response && response="yes"
        if [[ "${response:0:1}" = "n" ]] || [[ "${response:0:1}" = "N" ]]; then
            printf "- What category name would you like to set for this rule? [encrypted]\n"
            read category < /dev/tty
            test -z $category && category="encrypted"
        fi
    fi
    test -z $category && err "A valid category name needs to be specified."

    acl_command="navencrypt acl --add -r \"ALLOW @$category * $binary\""
    printf "\n==================================================\n"
    printf "\nNote! This is the command we will be using to add the ACL:\n"
    printf "\n\$ $acl_command\n"
    printf "\n==================================================\n"\n

    printf "Creating ACL rule...\n"
    cat $password_file | eval "$acl_command"
    if [[ $? -ne 0 ]]; then
        err "Could not add ACL for binary '$binary'. Please check command output for more information."
    fi
    printf "\n"
}

function printConclusion {
    printf "\nCompleted!\n"
    printf "We have randomly generated a password for you at '$password_file'. \nThis can (and should) be changed by running the following command:\n"
    printf "\n\t\$ navencrypt key --change\n"
    printf "\nWhich will prompt you for your own master password.\n"
}

function main {
    printBanner
    test $UID -eq 0 || err "Please run with administrative privileges."
    which navencrypt &>/dev/null || err "Please install Navencrypt before continuing."
    createRandomPassword
    registerClient
    prepareClient
    encryptData
    addRules
    printConclusion
}

main

exit 0
