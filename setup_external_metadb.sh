#!/usr/bin/env bash
# This script setups dockerized Redash on Ubuntu 18.04.
set -eu

REDASH_BASE_PATH=/opt/redash

install_docker(){
    # Install Docker
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get -qqy update
    DEBIAN_FRONTEND=noninteractive sudo -E apt-get -qqy -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade 
    sudo apt-get -yy install apt-transport-https ca-certificates curl software-properties-common wget pwgen
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
    sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
    sudo apt-get update && sudo apt-get -y install docker-ce

    # Install Docker Compose
    sudo curl -L https://github.com/docker/compose/releases/download/1.22.0/docker-compose-$(uname -s)-$(uname -m) -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose

    # Allow current user to run Docker commands
    sudo usermod -aG docker $USER
}

create_directories() {
    if [[ ! -e $REDASH_BASE_PATH ]]; then
        sudo mkdir -p $REDASH_BASE_PATH
        sudo chown $USER:$USER $REDASH_BASE_PATH
    fi

    if [[ ! -e $REDASH_BASE_PATH/redis-backup ]]; then
        mkdir $REDASH_BASE_PATH/redis-backup
    fi
}

create_config() {
    if [[ -e $REDASH_BASE_PATH/env ]]; then
        rm $REDASH_BASE_PATH/env
        touch $REDASH_BASE_PATH/env
    fi

    if [[ -e ./.env ]]; then
        # Load Environment Variables from Local .env
        # Environment Variables to be Loaded:
        #   COOKIE_SECRET
        #   SECRET_KEY
        #   POSTGRES_PASSWORD
        #   REDASH_DATABASE_URL
        export $(echo $(cat .env | sed 's/#.*//g'| xargs) | envsubst)
    fi

    echo "PYTHONUNBUFFERED=0" >> $REDASH_BASE_PATH/env
    echo "REDASH_LOG_LEVEL=INFO" >> $REDASH_BASE_PATH/env
    echo "REDASH_REDIS_URL=redis://redis:6379/0" >> $REDASH_BASE_PATH/env
    echo "REDASH_ADDITIONAL_QUERY_RUNNERS=redash.query_runner.python" >> $REDASH_BASE_PATH/env
    echo "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" >> $REDASH_BASE_PATH/env
    echo "REDASH_COOKIE_SECRET=$REDASH_COOKIE_SECRET" >> $REDASH_BASE_PATH/env
    echo "REDASH_SECRET_KEY=$REDASH_SECRET_KEY" >> $REDASH_BASE_PATH/env
    echo "REDASH_DATABASE_URL=$REDASH_DATABASE_URL" >> $REDASH_BASE_PATH/env
}

setup_compose() {
    REQUESTED_CHANNEL=stable
    LATEST_VERSION=`curl -s "https://version.redash.io/api/releases?channel=$REQUESTED_CHANNEL"  | json_pp  | grep "docker_image" | head -n 1 | awk 'BEGIN{FS=":"}{print $3}' | awk 'BEGIN{FS="\""}{print $1}'`

    cd $REDASH_BASE_PATH
    GIT_BRANCH="${REDASH_BRANCH:-master}" # Default branch/version to master if not specified in REDASH_BRANCH env var
    wget https://raw.githubusercontent.com/getredash/setup/${GIT_BRANCH}/data/docker-compose.yml
    sed -ri "s/image: redash\/redash:([A-Za-z0-9.-]*)/image: redash\/redash:$LATEST_VERSION/" docker-compose.yml
    echo "export COMPOSE_PROJECT_NAME=redash" >> ~/.profile
    echo "export COMPOSE_FILE=/opt/redash/docker-compose.yml" >> ~/.profile
    export COMPOSE_PROJECT_NAME=redash
    export COMPOSE_FILE=/opt/redash/docker-compose.yml
    
    # Edit redash-service not to depend on service postgres in docker-compose
    sed "/- postgres/d" /opt/redash/docker-compose.yml
    
    # Edit redis to bind volume /data to host file system directory
    export volumes="volumes:"
    export bind_directory="- /opt/redash/redis-backup:/data"
    sed -i "38 i \    ${volumes}" /opt/redash/docker-compose.yml
    sed -i "39 i \      ${bind_directory}" docker-compose.yml
    
    # Create and start containers except postgres
    sudo docker-compose run --rm server create_db
    sudo docker-compose up -d server scheduler scheduled_worker adhoc_worker redis nginx
}

install_docker
create_directories
create_config
setup_compose
