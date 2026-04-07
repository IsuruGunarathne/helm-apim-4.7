FROM eclipse-temurin:21-jdk-jammy

LABEL maintainer="WSO2 Docker Maintainers <dev@wso2.org>"

ENV LANG='en_US.UTF-8' LANGUAGE='en_US:en' LC_ALL='en_US.UTF-8'

# install required packages
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       tzdata curl ca-certificates fontconfig locales libxml2-utils netcat-openbsd unzip \
    && echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# wso2 user/group (matches Helm security context: UID/GID 10001)
ARG USER=wso2carbon
ARG USER_ID=10001
ARG USER_GROUP=wso2
ARG USER_GROUP_ID=10001
ARG USER_HOME=/home/${USER}

# component-specific build args
ARG WSO2_SERVER_NAME
ARG WSO2_SERVER_VERSION=4.7.0-SNAPSHOT
ARG WSO2_SERVER=${WSO2_SERVER_NAME}-${WSO2_SERVER_VERSION}
ARG WSO2_SERVER_HOME=${USER_HOME}/${WSO2_SERVER}
ARG STARTUP_SCRIPT

# create user and group
RUN groupadd --system -g ${USER_GROUP_ID} ${USER_GROUP} \
    && useradd --system --create-home --home-dir ${USER_HOME} \
       --no-log-init -g ${USER_GROUP_ID} -u ${USER_ID} ${USER}

# copy and extract the distribution ZIP
ARG ZIP_FILE
COPY --chown=wso2carbon:wso2 ${ZIP_FILE} /tmp/server.zip

RUN unzip -q -d ${USER_HOME} /tmp/server.zip \
    && chown -R wso2carbon:wso2 ${WSO2_SERVER_HOME} \
    && mkdir -p ${USER_HOME}/wso2-tmp \
    && mkdir -p ${USER_HOME}/solr/indexed-data ${USER_HOME}/solr/database \
    && chown -R wso2carbon:wso2 ${USER_HOME}/solr \
    # preserve shared deployment artifacts for entrypoint restore logic
    && if [ -d ${WSO2_SERVER_HOME}/repository/deployment/server/synapse-configs ]; then \
         cp -r ${WSO2_SERVER_HOME}/repository/deployment/server/synapse-configs ${USER_HOME}/wso2-tmp/; \
       fi \
    && if [ -d ${WSO2_SERVER_HOME}/repository/deployment/server/executionplans ]; then \
         cp -r ${WSO2_SERVER_HOME}/repository/deployment/server/executionplans ${USER_HOME}/wso2-tmp/; \
       fi \
    && rm -f /tmp/server.zip

# copy entrypoint
COPY --chown=wso2carbon:wso2 docker-entrypoint.sh ${USER_HOME}/
RUN chmod +x ${USER_HOME}/docker-entrypoint.sh

USER ${USER_ID}
WORKDIR ${USER_HOME}

ENV WORKING_DIRECTORY=${USER_HOME} \
    WSO2_SERVER_HOME=${WSO2_SERVER_HOME} \
    STARTUP_SCRIPT=${STARTUP_SCRIPT}

EXPOSE 9763 9443 8280 8243 9711 9611 5672 9099 8099 9021 8021

ENTRYPOINT ["/home/wso2carbon/docker-entrypoint.sh"]
