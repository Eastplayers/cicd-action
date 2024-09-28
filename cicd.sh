#/bin/bash

source ENV_FROM_GITHUB

##################################################
# General function
##################################################
BUILD_LOCATION=$(pwd)
get_github_information(){
  echo "
##################################################
Get Github information
##################################################
"
# Get workflow
  curl -L \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    https://api.github.com/repos/Eastplayers/$REPO_NAME/actions/runs?per_page=5 | jq ".workflow_runs | map(select(.run_number == $NUMBER_ACTIONS))" > temp_action.json

# Inject workflow info
  WORKFLOW_URL=$(cat temp_action.json | jq -r '.[].html_url')
  WORKFLOW_TIME_CREATE=$(cat temp_action.json | jq -r '.[].run_started_at')
  WORKFLOW_NAME=$(cat temp_action.json | jq -r '.[].name')
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  COMMIT_AUTHOR=$(cat temp_action.json | jq -r '.[].head_commit.author.name')
  COMMIT_MESSAGE=$(cat temp_action.json | jq -r '.[].head_commit.message')
  COMMIT_HASH_LONG=$(cat temp_action.json | jq -r '.[].head_commit.id')
  COMMIT_HASH_SHORT=$(echo "$COMMIT_HASH_LONG" | cut -c 1-7)
  TRIGGER_BY=$(cat temp_action.json | jq -r '.[].triggering_actor.login')
  TRIGGER_DISCORD_ID=$(docker exec env_vault vault kv get -format=json -mount="ep-infra" "cicd" | jq -r '.data.data.discord_member_id' | grep "$TRIGGER_BY" | awk -F '|' '{print $2}' | tr -d ' ')
  DEVOPS_TOKEN=$(docker exec env_vault vault kv get -format=json -mount="ep-infra" "cicd" | jq -r '.data.data.token')
  DISCORD_WEBHOOK=$(docker exec env_vault vault kv get -format=json -mount="ep-infra" "cicd" | jq -r '.data.data.discord_webhook')
}

get_env(){
  echo "
##################################################
Inject env
##################################################
"
  docker exec env_vault vault kv get -format=json -mount="$REPO_NAME" "$1" | jq -r '.data.data.env' > .env
  echo "Done !"
}

# Release note
gen_release_note(){
  cp ~/scripts/gen_release_note.sh .
  bash gen_release_note.sh production
  rm gen_release_note.sh
}

build_image(){
  echo "
##################################################
Building image
##################################################
"
  docker build -t eastplayers/$REPO_NAME:$BRANCH-$NUMBER_ACTIONS .
  docker tag eastplayers/$REPO_NAME:$BRANCH-$NUMBER_ACTIONS eastplayers/$REPO_NAME:$BRANCH-latest

  # Self-hosted registry
  docker tag eastplayers/$REPO_NAME:$BRANCH-$NUMBER_ACTIONS localhost:5000/eastplayers/$REPO_NAME:$BRANCH-$NUMBER_ACTIONS
  docker tag eastplayers/$REPO_NAME:$BRANCH-$NUMBER_ACTIONS localhost:5000/eastplayers/$REPO_NAME:$BRANCH-latest
}

push_image(){
  echo "
##################################################
Push image
##################################################
"
  cat << EOF > push_image
#!/bin/bash
  docker push -q eastplayers/$REPO_NAME:$BRANCH-$NUMBER_ACTIONS &
  docker push -q eastplayers/$REPO_NAME:$BRANCH-latest &
EOF
  chmod 700 push_image && nohup ./push_image &

  # Self-hosted registry
  docker push localhost:5000/eastplayers/$REPO_NAME:$BRANCH-$NUMBER_ACTIONS
  docker push localhost:5000/eastplayers/$REPO_NAME:$BRANCH-latest
}

deploy(){
  echo "
##################################################
Deploy Kubernetes
##################################################
"
  cd ~/ep-infra
  git pull
  sed -i "13s/.*/  tag: \"$BRANCH-$NUMBER_ACTIONS\"/" ~/ep-infra/v2/k8s/helm-chart/$GITOPS_PATH/values.yaml
  git config --global user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git config --global user.name "github-actions[bot]"
  git add .
  git commit -m "$REPO_NAME ($BRANCH) update image tag to $BRANCH-$NUMBER_ACTIONS"
  git push
}

deploy_docker_compose(){
  echo "
##################################################
Deploy Docker compose
##################################################
"    
  case "$1" in
    myhopy*)
      ssh epbot@157.245.196.86 "docker compose -f docker-config/docker-compose.yml pull && docker compose -f docker-config/docker-compose.yml up -d"
      ;;
    zalo-proxy*)
      ssh epbot@42.96.18.208 "docker compose -f docker-config/docker-compose.yml pull && docker compose -f docker-config/docker-compose.yml up -d"
      ;;
  esac
}

##################################################
# Discord Format
##################################################
send_notification_discord(){
  echo "
##################################################
  Send Notification Discord
##################################################
"  
  cd ~/scripts
  mkdir temp
  
# DISCORD FORMAT 
cat << EOF > ./temp/temp_status_discord_format.json
{
  "content": null,
  "embeds": [
    {
      "title": "WORKFLOW_CONCLUSION - $WORKFLOW_NAME",
      "color": DISCORD_COLOR,
      "fields": [
        {
          "name": "Repository",
          "value": "[$REPO_NAME](https://github.com/Eastplayers/$REPO_NAME)"
        },
        {
          "name": "Branch",
          "value": "[$BRANCH](https://github.com/Eastplayers/$REPO_NAME/tree/$BRANCH)"
        },
        {
          "name": "Commit",
          "value": "$COMMIT_AUTHOR - [\`$COMMIT_HASH_SHORT\`](https://github.com/Eastplayers/$REPO_NAME/commit/$COMMIT_HASH_LONG) \n\`$COMMIT_MESSAGE\`"
        },
        {
          "name": "Workflow",
          "value": "[$NUMBER_ACTIONS]($WORKFLOW_URL)"
        },
        {
          "name": "Trigger by",
          "value": "$TRIGGER_BY"
        }
      ],
      "timestamp": "$WORKFLOW_TIME_CREATE"
    }
  ],
  "attachments": []
}
EOF

cat << EOF > ./temp/temp_discord.sh
#!/bin/bash
sleep 20
  # Get workflow
  curl -L \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $DEVOPS_TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    https://api.github.com/repos/Eastplayers/$REPO_NAME/actions/runs?per_page=5 | jq ".workflow_runs | map(select(.run_number == $NUMBER_ACTIONS))" > temp_action.json

  WORKFLOW_CONCLUSION=\$(cat temp_action.json | jq -r '.[].conclusion')
  if [ "\$WORKFLOW_CONCLUSION" == "failure" ];then
  sed -i 's/"content": .*/"content": \"<@$TRIGGER_DISCORD_ID>\"\,/g' temp_status_discord_format.json
  sed -i "s/\bWORKFLOW_CONCLUSION\b/Failed/g" temp_status_discord_format.json
  sed -i "s/\bDISCORD_COLOR\b/\\"16711680\\"/g" temp_status_discord_format.json
  elif [ "\$WORKFLOW_CONCLUSION" == "success" ];then
  sed -i "s/\bWORKFLOW_CONCLUSION\b/Success/g" temp_status_discord_format.json
  sed -i "s/\bDISCORD_COLOR\b/\\"187764\\"/g" temp_status_discord_format.json
  fi

  DISCORD_EMBEDDED=\$(cat temp_status_discord_format.json)

  curl $DISCORD_WEBHOOK \\
      -H "Content-Type: application/json" \\
      -d "\$DISCORD_EMBEDDED"

EOF
chmod 700 ./temp/temp_discord.sh
cat << EOF > temp_Dockerfile
FROM ubuntu:22.04
RUN apt update
RUN apt install -y curl jq
COPY temp .
CMD bash temp_discord.sh
EOF

TEMP_NAME=$(date "+%s")
docker build -f temp_Dockerfile -t temp-$TEMP_NAME .
docker run --rm --name temp-$TEMP_NAME -d temp-$TEMP_NAME
}

# Cleaning
clean_disk_space(){
  echo "
##################################################
Cleaning
##################################################
"
  rm -rf $BUILD_LOCATION/* temp*
  
}

##################################################
# Custom function
##################################################
# Cxgenie be
cxgenie_be_get_ga_key(){
  echo "
##################################################
Get GA key
##################################################
"
  docker exec env_vault vault kv get -format=json -mount="$REPO_NAME" "ga-key" | jq -r '.data.data.env' > ga-key.json
  echo "Done !"
}

# Cxgenie chat web
cxgenie_chat_ticket_deploy (){
  echo "
##################################################
Compressing image
##################################################
"
  docker save eastplayers/$REPO_NAME:$BRANCH-latest | gzip > $REPO_NAME-$BRANCH.tar.gz
  if [ $BRANCH == "staging" ]; then
    CXGENIE_HOST="epbot@157.245.196.86"
    CXGENIE_NGINX="nginx_host1"
  elif [ $BRANCH == "production" ]; then
    CXGENIE_HOST="epbot@152.42.188.94"
    CXGENIE_NGINX="nginx_cxgenie"
  fi
    rsync -avz $REPO_NAME-$BRANCH.tar.gz $CXGENIE_HOST:~/
    rm $REPO_NAME-$BRANCH.tar.gz
    ssh $CXGENIE_HOST "docker load -i $REPO_NAME-$BRANCH.tar.gz && docker compose -f docker-config/docker-compose.yml up -d && rm $REPO_NAME-$BRANCH.tar.gz && docker exec $CXGENIE_NGINX nginx -t && docker exec $CXGENIE_NGINX nginx -s reload"
}

# Deploy cxgenie enterprise
deploy_cxg_enterprise(){
  CXG_ENTERPRISE_NAME=$(echo $BRANCH | awk -F '-' '{print $1}')
  echo "
##################################################
Deploying $CXG_ENTERPRISE_NAME
##################################################
"
  # if [[ "$1" == *"etp-baji"* ]]; then
  #   cd ~/cxgenie-etp-infra
  #   git pull
  #   sed -i "13s/.*/  tag: \"$BRANCH-$NUMBER_ACTIONS\"/" ~/cxgenie-etp-infra/$CXG_ENTERPRISE_NAME/helm-chart/$GITOPS_PATH/values.yaml
  #   git config --global user.email "41898282+github-actions[bot]@users.noreply.github.com"
  #   git config --global user.name "github-actions[bot]"
  #   git add .
  #   git commit -m "$REPO_NAME ($BRANCH) update image tag to $BRANCH-$NUMBER_ACTIONS"
  #   git push
  # else
    cd ~/cxgenie-etp-infra
    git pull
    sed -i "13s/.*/  tag: \"$BRANCH-$NUMBER_ACTIONS\"/" ~/cxgenie-etp-infra/$CXG_ENTERPRISE_NAME/$GITOPS_PATH/values.yaml
    git config --global user.email "41898282+github-actions[bot]@users.noreply.github.com"
    git config --global user.name "github-actions[bot]"
    git add .
    git commit -m "$REPO_NAME ($BRANCH) update image tag to $BRANCH-$NUMBER_ACTIONS"
    git push
  # fi
}

# Vnail full flow
vnail_tool_build_push(){
  echo "
##################################################
# Deploy Vnail tools 
##################################################  
  "
  docker exec env_vault vault kv get -format=json -mount="$REPO_NAME" "$BRANCH" | jq -r '.data.data.env' > Src/Domain/Appsettings/appsettings.json
  sed -i 's/image: registry.*/image: registry.eastplayers-tool.dev\/eastplayers\/vnails-tool:production-'$NUMBER_ACTIONS'/' docker-compose.yml
  docker compose build vnails_tool_production
  docker push registry.eastplayers-tool.dev/eastplayers/vnails-tool:production-$NUMBER_ACTIONS
}

##################################################
# Main Flow
##################################################
case "$1" in
  # Cxgenie Enterprise
  cxgenie-*-etp-*)
    get_github_information || { send_notification_discord; exit 1; }
    get_env $BRANCH || { send_notification_discord; exit 1; }
    if [[ "$1" == "cxgenie-be-etp"* ]]; then
      cxgenie_be_get_ga_key || { send_notification_discord; exit 1; }
    fi
    build_image || { send_notification_discord; exit 1; }
    push_image || { send_notification_discord; exit 1; }
    deploy_cxg_enterprise "$1" || { send_notification_discord; exit 1; }
    send_notification_discord
    clean_disk_space
    ;;

  # Cxgenie Production
  # BE
  cxgenie-be*)
    get_github_information || { send_notification_discord; exit 1; }
    get_env $BRANCH || { send_notification_discord; exit 1; }
    cxgenie_be_get_ga_key || { send_notification_discord; exit 1; }
    gen_release_note || { send_notification_discord; exit 1; }
    build_image || { send_notification_discord; exit 1; }
    push_image || { send_notification_discord; exit 1; }
    deploy || { send_notification_discord; exit 1; }
    send_notification_discord
    clean_disk_space
    ;;

  # Vnail
  vnails-tool*)
    get_github_information || { send_notification_discord; exit 1; }
    vnail_tool_build_push || { send_notification_discord; exit 1; }
    deploy || { send_notification_discord; exit 1; }
    send_notification_discord
    clean_disk_space
    ;;

  # Deploy to docker compose
  myhopy* | zalo-proxy*)
    get_github_information || { send_notification_discord; exit 1; }
    get_env $BRANCH || { send_notification_discord; exit 1; }
    gen_release_note || { send_notification_discord; exit 1; }
    build_image || { send_notification_discord; exit 1; }
    push_image || { send_notification_discord; exit 1; }
    deploy_docker_compose $1 || { send_notification_discord; exit 1; }
    send_notification_discord
    clean_disk_space
    ;;

  # Vercel
  *vercel)
    get_github_information || { send_notification_discord; exit 1; }
    gen_release_note || { send_notification_discord; exit 1; }
    send_notification_discord
    ;;

  # General
  *production | *staging)
    get_github_information || { send_notification_discord; exit 1; }
    get_env $BRANCH || { send_notification_discord; exit 1; }
    gen_release_note || { send_notification_discord; exit 1; }
    build_image || { send_notification_discord; exit 1; }
    push_image || { send_notification_discord; exit 1; }
    deploy || { send_notification_discord; exit 1; }
    send_notification_discord
    clean_disk_space
    ;;

esac
