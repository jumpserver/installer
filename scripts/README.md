# Jumpserver 商业快速部署
快速部署的运行环境是CentOS7 64位，root用户

在我们的oss里下载最新版的release文件传到客户的服务器上，如果客户服务器可以连接功能，可以使用curl，wget这类命令直接下载，速度应该比scp快。

解压后直接运行 install-jumpserver.sh 这个脚本。

执行完成即可在浏览器里访问IP:8088，如若可以成功访问，请执行以下命令

    docker restart jms_guacamole

然后再到jumpserver的"终端管理"页面选择接受两个app即可完成整个jumpserver的安装


