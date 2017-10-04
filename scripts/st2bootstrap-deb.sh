#!/usr/bin/env bash
# NOTE: This file is automatically generated by the tools/generate_final_installer_scripts.py
# script using the template file and common include files in scripts/includes/*.sh.
#
# DO NOT EDIT MANUALLY.
#
# Please edit corresponding template file and include files.

set -eu

HUBOT_ADAPTER='slack'
HUBOT_SLACK_TOKEN=${HUBOT_SLACK_TOKEN:-''}
VERSION=''
RELEASE='stable'
REPO_TYPE=''
REPO_PREFIX=''
ST2_PKG_VERSION=''
ST2MISTRAL_PKG_VERSION=''
ST2WEB_PKG_VERSION=''
ST2CHATOPS_PKG_VERSION=''
DEV_BUILD=''
USERNAME=''
PASSWORD=''
SUBTYPE=`lsb_release -a 2>&1 | grep Codename | grep -v "LSB" | awk '{print $2}'`
if [[ "$SUBTYPE" != 'trusty' && "$SUBTYPE" != 'xenial' ]]; then
  echo "Unsupported ubuntu flavor ${SUBTYPE}. Please use 14.04 (trusty) or 16.04 (xenial) as base system!"
  exit 2
fi


setup_args() {
  for i in "$@"
    do
      case $i in
          -v|--version=*)
          VERSION="${i#*=}"
          shift
          ;;
          -s|--stable)
          RELEASE=stable
          shift
          ;;
          -u|--unstable)
          RELEASE=unstable
          shift
          ;;
          --staging)
          REPO_TYPE='staging'
          shift
          ;;
          --dev=*)
          DEV_BUILD="${i#*=}"
          shift
          ;;
          --user=*)
          USERNAME="${i#*=}"
          shift
          ;;
          --password=*)
          PASSWORD="${i#*=}"
          shift
          ;;
          *)
          # unknown option
          ;;
      esac
    done

  if [[ "$REPO_TYPE" != '' ]]; then
      REPO_PREFIX="${REPO_TYPE}-"
  fi

  if [[ "$VERSION" != '' ]]; then
    if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+dev$ ]]; then
      echo "$VERSION does not match supported formats x.y.z or x.ydev"
      exit 1
    fi

    if [[ "$VERSION" =~ ^[0-9]+\.[0-9]+dev$ ]]; then
     echo "You're requesting a dev version! Switching to unstable!"
     RELEASE='unstable'
    fi
  fi

  echo "########################################################"
  echo "          Installing StackStorm $RELEASE $VERSION              "
  echo "########################################################"

  if [ "$REPO_TYPE" == "staging" ]; then
    printf "\n\n"
    echo "################################################################"
    echo "### Installing from staging repos!!! USE AT YOUR OWN RISK!!! ###"
    echo "################################################################"
  fi

  if [ "$DEV_BUILD" != '' ]; then
    printf "\n\n"
    echo "###############################################################################"
    echo "### Installing from dev build artifacts!!! REALLY, ANYTHING COULD HAPPEN!!! ###"
    echo "###############################################################################"
  fi

  if [[ "$USERNAME" = '' || "$PASSWORD" = '' ]]; then
    echo "Let's set StackStorm admin credentials."
    echo "You can also use \"--user\" and \"--password\" for unattended installation."
    echo "Press \"ENTER\" to continue or \"CTRL+C\" to exit/abort"
    read -e -p "Admin username: " -i "st2admin" USERNAME
    read -e -s -p "Password: " PASSWORD

    if [ "${PASSWORD}" = '' ]; then
        echo "Password cannot be empty."
        exit 1
    fi
  fi
}


function get_package_url() {
  # Retrieve direct package URL for the provided dev build, subtype and package name regex.
  DEV_BUILD=$1 # Repo name and build number - <repo name>/<build_num> (e.g. st2/5646)
  DISTRO=$2  # Distro name (e.g. trusty,xenial,el6,el7)
  PACKAGE_NAME_REGEX=$3

  PACKAGES_METADATA=$(curl -Ss -q https://circleci.com/api/v1.1/project/github/StackStorm/${DEV_BUILD}/artifacts)

  if [ -z "${PACKAGES_METADATA}" ]; then
      echo "Failed to retrieve packages metadata from https://circleci.com/api/v1.1/project/github/StackStorm/${DEV_BUILD}/artifacts" 1>&2
      return 2
  fi

  PACKAGES_URLS="$(echo ${PACKAGES_METADATA}  | jq -r '.[].url')"
  PACKAGE_URL=$(echo "${PACKAGES_URLS}" | egrep "${DISTRO}/${PACKAGE_NAME_REGEX}")

  if [ -z "${PACKAGE_URL}" ]; then
      echo "Failed to find url for ${DISTRO} package (${PACKAGE_NAME_REGEX})" 1>&2
      echo "Circle CI response: ${PACKAGES_METADATA}" 1>&2
      return 2
  fi

  echo ${PACKAGE_URL}
}


function port_status() {
  # If the specified tcp4 port is bound, then return the "port pid/procname",
  # else if a pipe command fails, return "Unbound",
  # else return "".
  #
  # Please note that all return values end with a newline.
  #
  # Use netstat and awk to get a list of all the tcp4 sockets that are in the LISTEN state,
  # matching the specified port.
  #
  # The `netstat -tunlp --inet` command is assumed to output data in the following format:
  #   Active Internet connections (only servers)
  #   Proto Recv-Q Send-Q Local Address           Foreign Address         State       PID/Program name
  #   tcp        0      0 0.0.0.0:80              0.0.0.0:*               LISTEN      7506/httpd
  #
  # The awk command prints the 4th and 7th columns of any line matching both the following criteria:
  #   1) The 4th column contains the port passed to port_status()  (i.e., $1)
  #   2) The 6th column contains "LISTEN"
  #
  # Sample output:
  #   0.0.0.0:25000 7506/sshd
  ret=$(sudo netstat -tunlp --inet | awk -v port=:$1 '$4 ~ port && $6 ~ /LISTEN/ { print $4 " " $7 }' || echo 'Unbound');
  echo "$ret";
}


check_st2_host_dependencies() {
  # CHECK 1: Determine which, if any, of the required ports are used by an existing process.

  # Abort the installation early if the following ports are being used by an existing process.
  # nginx (80, 443), mongodb (27017), rabbitmq (4369, 5672, 25672), postgresql (5432) and st2 (9100-9102).

  declare -a ports=("80" "443" "4369" "5432" "5672" "9100" "9101" "9102" "25672" "27017")
  declare -a used=()

  for i in "${ports[@]}"
  do
    rv=$(port_status $i)
    if [ "$rv" != "Unbound" ] && [ "$rv" != "" ]; then
      used+=("$rv")
    fi
  done

  # If any used ports were found, display helpful message and exit
  if [ ${#used[@]} -gt 0 ]; then
    printf "\nNot all required TCP ports are available. ST2 and related services will fail to start.\n\n"
    echo "The following ports are in use by the specified pid/process and need to be stopped:"
    for port_pid_process in "${used[@]}"
    do
       echo " $port_pid_process"
    done
    echo ""
    exit 1
  fi

  # CHECK 2: Ensure there is enough space at /var/lib/mongodb
  VAR_SPACE=`df -Pk /var/lib | grep -vE '^Filesystem|tmpfs|cdrom' | awk '{print $4}'`
  if [ ${VAR_SPACE} -lt 358400 ]; then
    echo ""
    echo "MongoDB 3.4 requires at least 350MB free in /var/lib/mongodb"
    echo "There is not enough space for MongoDB. It will fail to start."
    echo "Please, add some space to /var or clean it up."
    exit 1
  fi
}


generate_random_passwords() {
  # Generate random password used for MongoDB and PostgreSQL user authentication
  ST2_MONGODB_PASSWORD=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 24 ; echo '')
  ST2_POSTGRESQL_PASSWORD=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 24 ; echo '')
}


configure_st2_user () {
  # Create an SSH system user (default `stanley` user may be already created)
  if (! id stanley 2>/dev/null); then
    sudo useradd stanley
  fi

  SYSTEM_HOME=$(echo ~stanley)

  sudo mkdir -p ${SYSTEM_HOME}/.ssh

  # Generate ssh keys on StackStorm box and copy over public key into remote box.
  # NOTE: If the file already exists and is non-empty, then assume the key does not need
  # to be generated again.
  if ! sudo test -s ${SYSTEM_HOME}/.ssh/stanley_rsa; then
    sudo ssh-keygen -f ${SYSTEM_HOME}/.ssh/stanley_rsa -P ""
  fi

  if ! sudo grep -s -q -f ${SYSTEM_HOME}/.ssh/stanley_rsa.pub ${SYSTEM_HOME}/.ssh/authorized_keys;
  then
    # Authorize key-base access
    sudo sh -c "cat ${SYSTEM_HOME}/.ssh/stanley_rsa.pub >> ${SYSTEM_HOME}/.ssh/authorized_keys"
  fi

  sudo chmod 0600 ${SYSTEM_HOME}/.ssh/authorized_keys
  sudo chmod 0700 ${SYSTEM_HOME}/.ssh
  sudo chown -R stanley:stanley ${SYSTEM_HOME}

  # Enable passwordless sudo
  local STANLEY_SUDOERS="stanley    ALL=(ALL)       NOPASSWD: SETENV: ALL"
  if ! sudo grep -s -q ^"${STANLEY_SUDOERS}" /etc/sudoers.d/st2; then
    sudo sh -c "echo '${STANLEY_SUDOERS}' >> /etc/sudoers.d/st2"
  fi

  sudo chmod 0440 /etc/sudoers.d/st2

  # Disable requiretty for all users
  sudo sed -i -r "s/^Defaults\s+\+?requiretty/# Defaults requiretty/g" /etc/sudoers
}


configure_st2_cli_config() {
  # Configure CLI config (write credentials for the root user and user which ran the script)
  ROOT_USER="root"
  CURRENT_USER=$(whoami)

  ROOT_HOME=$(eval echo ~${ROOT_USER})
  : "${HOME:=$(eval echo ~${CURRENT_USER})}"

  ROOT_USER_CLI_CONFIG_DIRECTORY="${ROOT_HOME}/.st2"
  ROOT_USER_CLI_CONFIG_PATH="${ROOT_USER_CLI_CONFIG_DIRECTORY}/config"

  CURRENT_USER_CLI_CONFIG_DIRECTORY="${HOME}/.st2"
  CURRENT_USER_CLI_CONFIG_PATH="${CURRENT_USER_CLI_CONFIG_DIRECTORY}/config"

  if ! sudo test -d ${ROOT_USER_CLI_CONFIG_DIRECTORY}; then
    sudo mkdir -p ${ROOT_USER_CLI_CONFIG_DIRECTORY}
  fi

  sudo sh -c "cat <<EOT > ${ROOT_USER_CLI_CONFIG_PATH}
[credentials]
username = ${USERNAME}
password = ${PASSWORD}
EOT"

  # Write config for root user
  if [ "${CURRENT_USER}" == "${ROOT_USER}" ]; then
      return
  fi

  # Write config for current user (in case current user != root)
  if [ ! -d ${CURRENT_USER_CLI_CONFIG_DIRECTORY} ]; then
    sudo mkdir -p ${CURRENT_USER_CLI_CONFIG_DIRECTORY}
  fi

  sudo sh -c "cat <<EOT > ${CURRENT_USER_CLI_CONFIG_PATH}
[credentials]
username = ${USERNAME}
password = ${PASSWORD}
EOT"

  # Fix the permissions
  sudo chown -R ${CURRENT_USER}:${CURRENT_USER} ${CURRENT_USER_CLI_CONFIG_DIRECTORY}
}


generate_symmetric_crypto_key_for_datastore() {
  DATASTORE_ENCRYPTION_KEYS_DIRECTORY="/etc/st2/keys"
  DATASTORE_ENCRYPTION_KEY_PATH="${DATASTORE_ENCRYPTION_KEYS_DIRECTORY}/datastore_key.json"

  sudo mkdir -p ${DATASTORE_ENCRYPTION_KEYS_DIRECTORY}

  # If the file ${DATASTORE_ENCRYPTION_KEY_PATH} exists and is not empty, then do not generate
  # a new key. st2-generate-symmetric-crypto-key fails if the key file already exists.
  if ! sudo test -s ${DATASTORE_ENCRYPTION_KEY_PATH}; then
    sudo st2-generate-symmetric-crypto-key --key-path ${DATASTORE_ENCRYPTION_KEY_PATH}
  fi

  # Make sure only st2 user can read the file
  sudo chgrp st2 ${DATASTORE_ENCRYPTION_KEYS_DIRECTORY}
  sudo chmod o-r ${DATASTORE_ENCRYPTION_KEYS_DIRECTORY}
  sudo chgrp st2 ${DATASTORE_ENCRYPTION_KEY_PATH}
  sudo chmod o-r ${DATASTORE_ENCRYPTION_KEY_PATH}

  # set path to the key file in the config
  sudo crudini --set /etc/st2/st2.conf keyvalue encryption_key_path ${DATASTORE_ENCRYPTION_KEY_PATH}

  sudo st2ctl restart-component st2api
}


verify_st2() {
  st2 --version
  st2 -h

  st2 auth $USERNAME -p $PASSWORD
  # A shortcut to authenticate and export the token
  export ST2_AUTH_TOKEN=$(st2 auth $USERNAME -p $PASSWORD -t)

  # List the actions from a 'core' pack
  st2 action list --pack=core

  # Run a local shell command
  st2 run core.local -- date -R

  # See the execution results
  st2 execution list

  # Fire a remote comand via SSH (Requires passwordless SSH)
  st2 run core.remote hosts='127.0.0.1' -- uname -a

  # Install a pack
  st2 pack install st2
}


ok_message() {
  echo ""
  echo ""
  echo "███████╗████████╗██████╗      ██████╗ ██╗  ██╗";
  echo "██╔════╝╚══██╔══╝╚════██╗    ██╔═══██╗██║ ██╔╝";
  echo "███████╗   ██║    █████╔╝    ██║   ██║█████╔╝ ";
  echo "╚════██║   ██║   ██╔═══╝     ██║   ██║██╔═██╗ ";
  echo "███████║   ██║   ███████╗    ╚██████╔╝██║  ██╗";
  echo "╚══════╝   ╚═╝   ╚══════╝     ╚═════╝ ╚═╝  ╚═╝";
  echo ""
  echo "  st2 is installed and ready to use."
  echo ""
  echo "Head to https://YOUR_HOST_IP/ to access the WebUI"
  echo ""
  echo "Don't forget to dive into our documentation! Here are some resources"
  echo "for you:"
  echo ""
  echo "* Documentation  - https://docs.stackstorm.com"
  echo "* Pack Exchange - https://exchange.stackstorm.org/"
  echo ""
  echo "Thanks for installing StackStorm! Come visit us in our Slack Channel"
  echo "and tell us how it's going. We'd love to hear from you!"
  echo "http://stackstorm.com/community-signup"
}


fail() {
  echo "############### ERROR ###############"
  echo "# Failed on $STEP #"
  echo "#####################################"
  exit 2
}



install_st2_dependencies() {
  sudo apt-get update

  # Note: gnupg-curl is needed to be able to use https transport when fetching keys
  sudo apt-get install -y gnupg-curl
  sudo apt-get install -y curl
  sudo apt-get install -y rabbitmq-server

  # Configure RabbitMQ to listen on localhost only
  sudo sh -c 'echo "RABBITMQ_NODE_IP_ADDRESS=127.0.0.1" >> /etc/rabbitmq/rabbitmq-env.conf'

  if [[ "$SUBTYPE" == 'xenial' ]]; then
    sudo systemctl restart rabbitmq-server
  else
    sudo service rabbitmq-server restart
  fi

  # Various other dependencies needed by st2 and installer script
  sudo apt-get install -y crudini
}

install_mongodb() {
  # Add key and repo for the latest stable MongoDB (3.4)
  wget -qO - https://www.mongodb.org/static/pgp/server-3.4.asc | sudo apt-key add -
  echo "deb http://repo.mongodb.org/apt/ubuntu ${SUBTYPE}/mongodb-org/3.4 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-3.4.list

  sudo apt-get update
  sudo apt-get install -y mongodb-org

  # Configure MongoDB to listen on localhost only
  sudo sed -i -e "s#bindIp:.*#bindIp: 127.0.0.1#g" /etc/mongod.conf

  if [[ "$SUBTYPE" == 'xenial' ]]; then
    sudo systemctl enable mongod
    sudo systemctl start mongod
  else
    sudo service mongod restart
  fi

  sleep 5

  # Create admin user and user used by StackStorm (MongoDB needs to be running)
  mongo <<EOF
use admin;
db.createUser({
    user: "admin",
    pwd: "${ST2_MONGODB_PASSWORD}",
    roles: [
        { role: "userAdminAnyDatabase", db: "admin" }
    ]
});
quit();
EOF

  mongo <<EOF
use st2;
db.createUser({
    user: "stackstorm",
    pwd: "${ST2_MONGODB_PASSWORD}",
    roles: [
        { role: "readWrite", db: "st2" }
    ]
});
quit();
EOF

  # Require authentication to be able to acccess the database
  sudo sh -c 'echo "security:\n  authorization: enabled" >> /etc/mongod.conf'

  # MongoDB needs to be restarted after enabling auth
  if [[ "$SUBTYPE" == 'xenial' ]]; then
    sudo systemctl restart mongod
  else
    sudo service mongod restart
  fi

}

get_full_pkg_versions() {
  if [ "$VERSION" != '' ];
  then
    local ST2_VER=$(apt-cache show st2 | grep Version | awk '{print $2}' | grep ^${VERSION//./\\.} | sort --version-sort | tail -n 1)
    if [ -z "$ST2_VER" ]; then
      echo "Could not find requested version of StackStorm!!!"
      sudo apt-cache policy st2
      exit 3
    fi

    local ST2MISTRAL_VER=$(apt-cache show st2mistral | grep Version | awk '{print $2}' | grep ^${VERSION//./\\.} | sort --version-sort | tail -n 1)
    if [ -z "$ST2MISTRAL_VER" ]; then
      echo "Could not find requested version of st2mistral!!!"
      sudo apt-cache policy st2mistral
      exit 3
    fi

    local ST2WEB_VER=$(apt-cache show st2web | grep Version | awk '{print $2}' | grep ^${VERSION//./\\.} | sort --version-sort | tail -n 1)
    if [ -z "$ST2WEB_VER" ]; then
      echo "Could not find requested version of st2web."
      sudo apt-cache policy st2web
      exit 3
    fi

    local ST2CHATOPS_VER=$(apt-cache show st2chatops | grep Version | awk '{print $2}' | grep ^${VERSION//./\\.} | sort --version-sort | tail -n 1)
    if [ -z "$ST2CHATOPS_VER" ]; then
      echo "Could not find requested version of st2chatops."
      sudo apt-cache policy st2chatops
      exit 3
    fi

    ST2_PKG_VERSION="=${ST2_VER}"
    ST2MISTRAL_PKG_VERSION="=${ST2MISTRAL_VER}"
    ST2WEB_PKG_VERSION="=${ST2WEB_VER}"
    ST2CHATOPS_PKG_VERSION="=${ST2CHATOPS_VER}"
    echo "##########################################################"
    echo "#### Following versions of packages will be installed ####"
    echo "st2${ST2_PKG_VERSION}"
    echo "st2mistral${ST2MISTRAL_PKG_VERSION}"
    echo "st2web${ST2WEB_PKG_VERSION}"
    echo "st2chatops${ST2CHATOPS_PKG_VERSION}"
    echo "##########################################################"
  fi
}

install_st2() {
  # Following script adds a repo file, registers gpg key and runs apt-get update
  curl -s https://packagecloud.io/install/repositories/StackStorm/${REPO_PREFIX}${RELEASE}/script.deb.sh | sudo bash

  # 'mistral' repo builds single 'st2mistral' package and so we have to install 'st2' from repo
  if [ "$DEV_BUILD" = '' ] || [[ "$DEV_BUILD" =~ ^mistral/.* ]]; then
    STEP="Get package versions" && get_full_pkg_versions && STEP="Install st2"
    sudo apt-get install -y st2${ST2_PKG_VERSION}
  else
    sudo apt-get install -y jq

    PACKAGE_URL=$(get_package_url "${DEV_BUILD}" "${SUBTYPE}" "st2_.*.deb")
    PACKAGE_FILENAME="$(basename ${PACKAGE_URL})"
    curl -Ss -k -o ${PACKAGE_FILENAME} ${PACKAGE_URL}
    sudo dpkg -i --force-depends ${PACKAGE_FILENAME}
    sudo apt-get install -yf
    rm ${PACKAGE_FILENAME}
  fi

  # Configure [database] section in st2.conf (username password for MongoDB access)
  sudo crudini --set /etc/st2/st2.conf database username "stackstorm"
  sudo crudini --set /etc/st2/st2.conf database password "${ST2_MONGODB_PASSWORD}"

  sudo st2ctl start
  sudo st2ctl reload --register-all
}


configure_st2_authentication() {
  # Install htpasswd tool for editing ini files
  sudo apt-get install -y apache2-utils

  # Create a user record in a password file.
  sudo echo "${PASSWORD}" | sudo htpasswd -i /etc/st2/htpasswd $USERNAME

  # Configure [auth] section in st2.conf
  sudo crudini --set /etc/st2/st2.conf auth enable 'True'
  sudo crudini --set /etc/st2/st2.conf auth backend 'flat_file'
  sudo crudini --set /etc/st2/st2.conf auth backend_kwargs '{"file_path": "/etc/st2/htpasswd"}'

  sudo st2ctl restart-component st2api
  sudo st2ctl restart-component st2stream
}

install_st2mistral_dependencies() {
  sudo apt-get install -y postgresql

  # Configure service only listens on localhost
  sudo crudini --set /etc/postgresql/*/main/postgresql.conf '' listen_addresses "'127.0.0.1'"

  sudo service postgresql restart
  cat << EHD | sudo -u postgres psql
CREATE ROLE mistral WITH CREATEDB LOGIN ENCRYPTED PASSWORD '${ST2_POSTGRESQL_PASSWORD}';
CREATE DATABASE mistral OWNER mistral;
EHD
}

install_st2mistral() {
  # 'st2' repo builds single 'st2' package and so we have to install 'st2mistral' from repo
  if [ "$DEV_BUILD" = '' ] || [[ "$DEV_BUILD" =~ ^st2/.* ]]; then
    sudo apt-get install -y st2mistral${ST2MISTRAL_PKG_VERSION}
  else
    sudo apt-get install -y jq

    PACKAGE_URL=$(get_package_url "${DEV_BUILD}" "${SUBTYPE}" "st2mistral_.*.deb")
    PACKAGE_FILENAME="$(basename ${PACKAGE_URL})"
    curl -Ss -k -o ${PACKAGE_FILENAME} ${PACKAGE_URL}
    sudo dpkg -i --force-depends ${PACKAGE_FILENAME}
    sudo apt-get install -yf
    rm ${PACKAGE_FILENAME}
  fi

  # Configure database settings
  sudo crudini --set /etc/mistral/mistral.conf database connection "postgresql+psycopg2://mistral:${ST2_POSTGRESQL_PASSWORD}@127.0.0.1/mistral"

  # Setup Mistral DB tables, etc.
  /opt/stackstorm/mistral/bin/mistral-db-manage --config-file /etc/mistral/mistral.conf upgrade head

  # Register mistral actions.
  /opt/stackstorm/mistral/bin/mistral-db-manage --config-file /etc/mistral/mistral.conf populate | grep -v openstack

  # Start Mistral
  sudo service mistral start
}

install_st2web() {
  # Add key and repo for the latest stable nginx
  sudo apt-key adv --fetch-keys http://nginx.org/keys/nginx_signing.key
  sudo sh -c "cat <<EOT > /etc/apt/sources.list.d/nginx.list
deb http://nginx.org/packages/ubuntu/ ${SUBTYPE} nginx
deb-src http://nginx.org/packages/ubuntu/ ${SUBTYPE} nginx
EOT"
  sudo apt-get update

  # Install st2web and nginx
  sudo apt-get install -y st2web${ST2WEB_PKG_VERSION} nginx

  # Generate self-signed certificate or place your existing certificate under /etc/ssl/st2
  sudo mkdir -p /etc/ssl/st2
  sudo openssl req -x509 -newkey rsa:2048 -keyout /etc/ssl/st2/st2.key -out /etc/ssl/st2/st2.crt \
  -days XXX -nodes -subj "/C=US/ST=California/L=Palo Alto/O=StackStorm/OU=Information \
  Technology/CN=$(hostname)"

  # Remove default site, if present
  sudo rm -f /etc/nginx/conf.d/default.conf
  # Copy and enable StackStorm's supplied config file
  sudo cp /usr/share/doc/st2/conf/nginx/st2.conf /etc/nginx/conf.d/

  sudo service nginx restart

  # st2web logs shouldn't be read by others
  sudo chmod o-r /var/log/nginx/st2webui.* /var/log/nginx/ssl-st2webui.*
}

install_st2chatops() {
  # Add NodeJS 6 repo
  curl -sL https://deb.nodesource.com/setup_6.x | sudo -E bash -

  # Install st2chatops
  sudo apt-get install -y st2chatops${ST2CHATOPS_PKG_VERSION}
}

configure_st2chatops() {
  # set API keys. This should work since CLI is configuered already.
  ST2_API_KEY=`st2 apikey create -k`
  sudo sed -i -r "s/^(export ST2_API_KEY.).*/\1$ST2_API_KEY/" /opt/stackstorm/chatops/st2chatops.env

  sudo sed -i -r "s/^(export ST2_AUTH_URL.).*/# &/" /opt/stackstorm/chatops/st2chatops.env
  sudo sed -i -r "s/^(export ST2_AUTH_USERNAME.).*/# &/" /opt/stackstorm/chatops/st2chatops.env
  sudo sed -i -r "s/^(export ST2_AUTH_PASSWORD.).*/# &/" /opt/stackstorm/chatops/st2chatops.env

  # Setup adapter
  if [ "$HUBOT_ADAPTER"="slack" ] && [ ! -z "$HUBOT_SLACK_TOKEN" ]
  then
    sudo sed -i -r "s/^# (export HUBOT_ADAPTER=slack)/\1/" /opt/stackstorm/chatops/st2chatops.env
    sudo sed -i -r "s/^# (export HUBOT_SLACK_TOKEN.).*/\1/" /opt/stackstorm/chatops/st2chatops.env
    sudo sed -i -r "s/^(export HUBOT_ADAPTER.).*/\1$HUBOT_ADAPTER/" /opt/stackstorm/chatops/st2chatops.env
    sudo sed -i -r "s/^(export HUBOT_SLACK_TOKEN.).*/\1$HUBOT_SLACK_TOKEN/" /opt/stackstorm/chatops/st2chatops.env

    sudo service st2chatops restart
  else
    echo "####################### WARNING ########################"
    echo "######## Chatops requires manual configuration #########"
    echo "Edit /opt/stackstorm/chatops/st2chatops.env to specify  "
    echo "the adapter and settings hubot should use to connect to "
    echo "the chat you're using. Don't forget to start the service"
    echo "afterwards:"
    echo ""
    echo "  $ sudo service st2chatops restart"
    echo ""
    echo "For more information, please refer to documentation at  "
    echo "https://docs.stackstorm.com/install/deb.html#setup-chatops"
    echo "########################################################"
  fi
}


## Let's do this!

trap 'fail' EXIT
STEP="Setup args" && setup_args $@
STEP="Check TCP ports and MongoDB storage requirements" && check_st2_host_dependencies
STEP="Generate random password" && generate_random_passwords
STEP="Install st2 dependencies" && install_st2_dependencies
STEP="Install st2 dependencies (MongoDB)" && install_mongodb
STEP="Install st2" && install_st2
STEP="Configure st2 user" && configure_st2_user
STEP="Configure st2 auth" && configure_st2_authentication
STEP="Configure st2 CLI config" && configure_st2_cli_config
STEP="Generate symmetric crypto key for datastore" && generate_symmetric_crypto_key_for_datastore
STEP="Verify st2" && verify_st2

STEP="Install mistral dependencies" && install_st2mistral_dependencies
STEP="Install mistral" && install_st2mistral

STEP="Install st2web" && install_st2web

STEP="Install st2chatops" && install_st2chatops
STEP="Configure st2chatops" && configure_st2chatops
trap - EXIT

ok_message
