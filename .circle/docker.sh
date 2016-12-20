#!/bin/bash
set -e

### Pass these ENV Variables for this script to consume:
# BUILD_DOCKER - Should this script build Docker images or exit? (0/1)
# DEPLOY_DOCKER - Should this script push created images to Docker Hub? (0/1)

# DOCKER_USER - Docker Hub Username to login
# DOCKER_EMAIL - Docker Hub Email to login
# DOCKER_PASSWORD - Docker Hub Password to Login

# DISTRO - Distro name, we build Docker images only for wheezy distro (ex: wheezy)
# ST2_DOCKERFILES_REPO - GitHub repository with Dockerfiles (https://github.com/StackStorm/st2-dockerfiles)
# ST2_GITREV - st2 branch name (ex: master, v1.2.1). This will be used to determine correct Docker Tag: `latest`, `1.2.1`
# ST2PKG_VERSION - st2 version, will be reused in Docker image metadata (ex: 1.2dev)
# ST2PKG_RELEASE - Release number aka revision number for `st2` package, will be reused in Docker metadata (ex: 4)

### Usage:
# docker.sh build st2 - Build base Docker image with `st2` installed. This will be reused by child containers
# docker.sh build st2actionrunner st2api st2auth st2exporter st2notifier st2resultstracker st2rulesengine st2sensorcontainer - Build child Docker images based on `st2`, - previously created Docker image
# docker.sh run st2api - Start detached `st2api` docker image
# docker.sh test st2api 'st2 --version' - Exec command inside already started `st2api` Docker container
# docker.sh deploy st2api st2auth st2exporter st2notifier st2resultstracker st2rulesengine st2sensorcontainer - Push images to Docker Hub

: ${BUILD_DOCKER:=0}
: ${DEPLOY_DOCKER:=0}

if [ ${DISTRO} != 'wheezy' ]; then
    echo "Skipping the Docker stage for ${DISTRO}."
    echo "We build Docker images based on 'wheezy' only."
    exit
fi

if [ ${BUILD_DOCKER} -eq 0 ]; then
  echo 'Skipping the Docker stage because BUILD_DOCKER=0'
  exit
fi

# Required ENV variables
: ${DISTRO:? DISTRO env is required}
: ${ST2_DOCKERFILES_REPO:? ST2_DOCKERFILES_REPO env is required}
: ${ST2_DOCKERFILES_REPO:? ST2_GITREV env is required}
# TODO: Parse these vars from `st2_1.2dev-1_amd64.deb`
: ${ST2PKG_VERSION:? ST2PKG_VERSION env is required}
: ${ST2PKG_RELEASE:? ST2PKG_RELEASE env is required}

# Get Docker Tag from the current st2 branch name
if [ "${ST2_GITREV}" == 'master' ]; then
  DOCKER_TAG=latest
elif echo "${ST2_GITREV}" | grep -q '^v[0-9]\+\.[0-9]\+$'; then
  DOCKER_TAG=${ST2PKG_VERSION}
else
  DEPLOY_DOCKER=0
fi

# Clone remote repo with Dockerfiles
if [ ! -d "st2-dockerfiles" ]; then
  git clone ${ST2_DOCKERFILES_REPO}
fi

cd st2-dockerfiles

case "$1" in
  build)
    case "$2" in
      st2)
        cp /tmp/st2-packages/st2*.deb stackstorm/
        docker build --build-arg ST2_VERSION="${ST2PKG_VERSION}-${ST2PKG_RELEASE}" -t st2 stackstorm/
      ;;
      *)
        for container in "${@:2}"; do
          docker build -t stackstorm/${container}:${DOCKER_TAG} ${container}
        done
      ;;
    esac
  ;;
  run)
    docker run --name "$2" -d stackstorm/"$2":${DOCKER_TAG}
  ;;
  test)
    # Verify Container by running `st2` command in it
    # Same as: docker exec st2docker st2 --version
    # See: https://circleci.com/docs/docker#docker-exec
    sudo lxc-attach -n "$(docker inspect --format '{{.Id}}' ${2})" -- bash -c "${3}"
  ;;
  deploy)
    if [ ${DEPLOY_DOCKER} -eq 0 ]; then
      echo 'Skipping Docker push because DEPLOY_DOCKER=0'
      exit
    fi

    docker login -e ${DOCKER_EMAIL} -u ${DOCKER_USER} -p ${DOCKER_PASSWORD}

    echo 'Pushing StackStorm images to Docker Hub in parallel ...'
    parallel -v -j0 --line-buffer docker push stackstorm/{}:${DOCKER_TAG} ::: ${@:2}
  ;;
esac
