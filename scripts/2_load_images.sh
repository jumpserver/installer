#!/bin/bash
# Copyright (c) 2014-2020 Fit2cloud Tech, Inc., All rights reserved.
# Author: JumpServer Team
# Mail: support@fit2cloud.com
#

BASE_DIR=$(dirname "$0")
source ${BASE_DIR}/utils.sh
IMAGE_DIR=images

cd "${BASE_DIR}" || return

function load_image() {
    echo ">>> 加载镜像"
    images=$(get_images)
    for image in ${images};do
        filename=$(basename ${image}).tar
        filename_windows=${filename/:/_}
        has_file=0
        if [[ -f ${IMAGE_DIR}/${filename_windows} ]];then
            filename=${filename_windows}
            has_file=1
        fi
        if [[ -f ${filename} ]];then
            docker load < ${IMAGE_DIR}/${filename}
            has_file=1
        fi
        if [[ "${has_file}" == '0' ]];then
          echo "Error: Image file 丢失: ${filename}"
        fi
    done
}

function pull_image() {
    echo ">>> 拉取镜像"
    images=$(get_images public)
    for image in ${images};do
      docker pull "${image}"
    done
}


