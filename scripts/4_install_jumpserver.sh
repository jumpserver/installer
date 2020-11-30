#!/usr/bin/env bash

cat << "EOF"
   ___                       _____
  |_  |                     /  ___|
    | |_   _ _ __ ___  _ __ \ `--.  ___ _ ____   _____ _ __
    | | | | | '_ ` _ \| '_ \ `--. \/ _ \ '__\ \ / / _ \ '__|
/\__/ / |_| | | | | | | |_) /\__/ /  __/ |   \ V /  __/ |
\____/ \__,_|_| |_| |_| .__/\____/ \___|_|    \_/ \___|_|
                      | |
                      |_|

## 准备安装 JumpServer
EOF

(bash ./scripts/1_install_docker.sh)
(bash ./scripts/2_load_images.sh)
(bash ./scripts/3_config_jumpserver.sh)