#!/usr/bin/env bashio
set -e

local_repository='/data/repository'
pull_before_push="$(bashio::config 'repository.pull_before_push')"

function setup_git {
    repository=$(bashio::config 'repository.url')
    username=$(bashio::config 'repository.username')
    password=$(bashio::config 'repository.password')

    if [ ! -d $local_repository ]; then
        bashio::log.info 'Create local repository'
        mkdir -p $local_repository
    fi
    cd $local_repository

    if [ ! -d .git ]; then
        fullurl="https://${username}:${password}@${repository##*https://}"
        if [ "$pull_before_push" == 'true' ]; then
            bashio::log.info 'Clone existing repository'
            git clone $fullurl $local_repository
        else
            bashio::log.info 'Initialize new repository'
            git init $local_repository
            git remote add origin $fullurl
        fi
        git config user.name "${username}"
        git config user.email 'git.exporter@hass.io'
    fi

    #Reset secrets if existing
    git config --unset-all 'secrets.allowed' || true
    git config --unset-all 'secrets.patterns' || true
    git config --unset-all 'secrets.providers' || true

    if [ "$pull_before_push" == 'true' ]; then
        bashio::log.info 'Pull latest'
        git reset --hard
        git pull --rebase
    fi
}

function check_secrets {
    check_for_secrets=$(bashio::config 'check.check_for_secrets')
    check_for_ips=$(bashio::config 'check.check_for_ips')

    if [ "$check_for_secrets" == 'true' ]; then
        bashio::log.info 'Add secrets pattern'

        # Allow !secret lines
        git secrets --add -a '!secret'

        # Set prohibited patterns
        git secrets --add "password:\s?[\'\"]?\w+[\'\"]?\n?"
        git secrets --add "token:\s?[\'\"]?\w+[\'\"]?\n?"
        git secrets --add "client_id:\s?[\'\"]?\w+[\'\"]?\n?"
        git secrets --add "api_key:\s?[\'\"]?\w+[\'\"]?\n?"
        git secrets --add "chat_id:\s?[\'\"]?\w+[\'\"]?\n?"
        git secrets --add "allowed_chat_ids:\s?[\'\"]?\w+[\'\"]?\n?"
        git secrets --add "latitude:\s?[\'\"]?\w+[\'\"]?\n?"
        git secrets --add "longitude:\s?[\'\"]?\w+[\'\"]?\n?"

        git secrets --add-provider -- sed '/^$/d;/^#.*/d;/^&/d;s/^.*://g;s/\s//g' /config/secrets.yaml

        if [ "$check_for_ips" == 'true' ]; then
            git secrets --add '([0-9]{1,3}\.){3}[0-9]{1,3}'
            git secrets --add '([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})'
        fi

        bashio::log.info 'Add secrets from secrets.yaml'
        prohibited_patterns=$(git config --get-all secrets.patterns)
        bashio::log.info "Prohibited patterns:\n${prohibited_patterns//\\n/\\\\n}"

        bashio::log.info 'Checking for secrets'
        git secrets --scan $(find $local_repository -name '*.yaml' -o -name '*.yml' -o -name '*.json' -o -name '*.disabled') \
        || bashio::log.error 'Found secrets in files!!! Fix them to be able to commit!'; exit 1
    fi
}

bashio::log.info 'Start git export'

setup_git

excludes=$(bashio::config 'exclude')
excludes=("secrets.yaml" ".storage" ".cloud" "esphome" "${excludes[@]}")

bashio::log.info 'Get Home Assistant config'
exclude_args=$(printf -- '--exclude=%s ' ${excludes[@]})
rsync -archive --checksum --prune-empty-dirs -q $exclude_args /config ${local_repository}
sed 's/:.*$/: ""/g' /config/secrets.yaml > ${local_repository}/config/secrets.yaml

bashio::log.info 'Get Lovelace config yaml'
[ ! -d "${local_repository}/lovelace" ] && mkdir "${local_repository}/lovelace"
python3 -c "import sys, yaml, json; yaml.safe_dump(json.load(sys.stdin)['data']['config'], sys.stdout, default_flow_style=False)" \
    < /config/.storage/lovelace > "${local_repository}/lovelace/config.yaml"

if [ -d '/config/esphome' ]; then
    bashio::log.info 'Get ESPHome configs'
    rsync -archive --checksum --prune-empty-dirs -q \
        --exclude='.esphome/' --include="*/" --include='*.yaml' --include='*.disabled' --exclude='*' \
        /config/esphome ${local_repository}
fi

bashio::log.info 'Get addon configs'

check_secrets

bashio::log.info 'Commit changes and push to remote'
git add .
git commit -m "Home Assistant Config Export"

if [ ! "$pull_before_push" == 'true' ]; then
    git push --set-upstream origin master -f
else
    git push origin
fi