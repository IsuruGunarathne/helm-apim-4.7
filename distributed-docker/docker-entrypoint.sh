#!/bin/bash
set -e

# volume mounts
config_volume=${WORKING_DIRECTORY}/wso2-config-volume
artifact_volume=${WORKING_DIRECTORY}/wso2-artifact-volume
deployment_volume=${WSO2_SERVER_HOME}/repository/deployment/server
original_deployment_artifacts=${WORKING_DIRECTORY}/wso2-tmp

# check if the WSO2 non-root user home exists
test ! -d ${WORKING_DIRECTORY} && echo "WSO2 Docker non-root user home does not exist" && exit 1

# check if the WSO2 product home exists
test ! -d ${WSO2_SERVER_HOME} && echo "WSO2 Docker product home does not exist" && exit 1

# restore default deployment artifacts if shared directories are empty
directories=("executionplans" "synapse-configs")
for shared_directory in ${directories[@]}; do
    if test -d ${original_deployment_artifacts}/${shared_directory}; then
        if [[ -z "$(ls -A ${deployment_volume}/${shared_directory} 2>/dev/null)" ]]; then
            if ! cp -R ${original_deployment_artifacts}/${shared_directory}/* ${deployment_volume}/${shared_directory}/ 2>/dev/null; then
                echo "No default artifacts to copy for ${shared_directory}"
            else
                echo "Successfully copied preserved default artifacts to ${deployment_volume}/${shared_directory}"
            fi
        fi
    fi
done

# copy any configuration changes mounted to config_volume
test -d ${config_volume} && [[ "$(ls -A ${config_volume})" ]] && cp -RL ${config_volume}/* ${WSO2_SERVER_HOME}/

# copy any artifact changes mounted to artifact_volume
test -d ${artifact_volume} && [[ "$(ls -A ${artifact_volume})" ]] && cp -RL ${artifact_volume}/* ${WSO2_SERVER_HOME}/

# start WSO2 Carbon server
echo "Starting WSO2 server with ${STARTUP_SCRIPT}..." >&2
sh ${WSO2_SERVER_HOME}/bin/${STARTUP_SCRIPT} "$@"
