#!/bin/bash
# Copyright (c) 2014-2020 Fit2cloud Tech, Inc., All rights reserved.
# Author: JumpServer Team
# Mail: support@fit2cloud.com
#

BASE_DIR=$(dirname "$0")
source ${BASE_DIR}/utils.sh
IMAGE_DIR=images

cd ${BASE_DIR}
images=$(get_images)

echo ">>> 加载镜像"
for image in ${images};do
    filename=$(basename ${image}).tar
    filename_windows=${filename/:/_}
    if [[ -f ${IMAGE_DIR}/${filename_windows} ]];then
        filename=${filename_windows}
    fi
    if [[ -f ${filename} ]];then
        docker load < ${IMAGE_DIR}/${filename}
    fi
done
