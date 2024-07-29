def getBuildArgs() {
    def buildArgs = ''
    if (env.pull_image == "Yes") {
        buildArgs = '--pull'
    }
    if (env.no_cache == "Yes") {
        buildArgs += ' --no-cache'
    }
    if (env.build_arm == "Yes") {
        buildArgs += ' --platform linux/amd64,linux/arm64'
    } else {
        buildArgs += ' --platform linux/amd64'
    }
    return buildArgs
}

def getPassArgs() {
    def passArgs = " --build-arg VERSION=${env.release_version}"
    if (env.APT_MIRROR) {
        passArgs += " --build-arg APT_MIRROR=${env.APT_MIRROR}"
    }
    if (env.PIP_MIRROR) {
        passArgs += " --build-arg PIP_MIRROR=${env.PIP_MIRROR}"
    }
    if (env.MAVEN_MIRROR) {
        passArgs += " --build-arg MAVEN_MIRROR=${env.MAVEN_MIRROR}"
    }
    if (env.NPM_MIRROR) {
        passArgs += " --build-arg NPM_MIRROR=${env.NPM_MIRROR}"
    }
    return passArgs
}

def beforeBuild() {
    if (env.build_use_registry == "Yes") {
        sh "sed -i 's@^FROM debian@FROM registry.fit2cloud.com/jumpserver/debian@g' Dockerfile"
        sh "sed -i 's@^FROM jumpserver@FROM registry.fit2cloud.com/jumpserver@g' Dockerfile"
        sh "sed -i 's@^FROM node@FROM registry.fit2cloud.com/jumpserver/node@g' Dockerfile"
        sh "sed -i 's@^FROM golang@FROM registry.fit2cloud.com/jumpserver/golang@g' Dockerfile"
    }
}

def sendErrorMsg(imageName) {
    def webhookUrl = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=${WECHAT_BOT_KEY}"
    def payload = """
    {
        "msgtype": "text",
        "text": {
            "content": "【构建通知】
                任务名称: ${env.JOB_NAME}
                构建编号: 第 ${env.BUILD_NUMBER} 次构建
                构建镜像: ${imageName}
                构建状态: 失败
                构建日志: ${env.BUILD_URL}console"
        }
    }
    """
    sh "curl -H 'Content-Type: application/json' -d '${payload}' ${webhookUrl}"
}

def syncToDockerHubIfNeed(fullName, imageName) {
    if (env.upload_to_docker != "Yes") {
        return 0
    }

    if (imageName.endsWith("-ee")) {
        println "企业版不上传到 Docker Hub"
        return
    }

    for (i in 1..5) {
        if (sh(script: "crane cp ${fullName} ${imageName}", returnStatus: true) == 0) {
            break
        }
        sleep(5)
        if (i == 3) {
            sendErrorMsg(imageName)
            println "[Error]: push 失败"
            return 1
        }
    }
}

def releaseToGitHubIfNeed() {
    if (env.github_release == "Yes") {
        if (sh(script: "git tag | grep '${env.release_version}'", returnStatus: true) == 0) {
            sh "git tag -d '${env.release_version}' || true"
            sh "git push origin --delete tag '${env.release_version}' || true"
        }

        sh "git tag '${env.release_version}'"
        sh "git push origin ${env.release_version}"
    }
}

def buildImage(appName, appVersion, extraBuildArgs = '') {
    def buildArgs = getBuildArgs()
    if (extraBuildArgs) {
        buildArgs += " ${extraBuildArgs}"
    }

    def passArgs = getPassArgs()
    buildArgs += " ${passArgs}"

    if (appName == "jumpserver") {
        appName = "core"
    } else if (appName == "docker-web") {
        appName = "web"
    } else if (appName == "core-xpack") {
        appName = "xpack"
    }

    def imageName = "jumpserver/${appName}:${appVersion}"
    def fullName = "registry.fit2cloud.com/${imageName}"
    if (env.only_docker_image == "Yes") {
        fullName = imageName
    }

    sh("pwd; ls")

    for (i in 1..5) {
        if (sh(
                script: "docker buildx build ${buildArgs} -t ${fullName} . --push",
                returnStatus: true
        ) == 0) {
            break
        }
        sleep(5)
        if (i == 3) {
            sendErrorMsg(imageName)
            println "[Error]: build 失败"
            return 1
        }
    }
    syncToDockerHubIfNeed(fullName, imageName)
    releaseToGitHubIfNeed()
}

def buildEE(appName, appVersion, extraBuildArgs = '') {
    if (fileExists('Dockerfile-ee')) {
        extraBuildArgs += ' -f Dockerfile-ee'
    }
    buildImage(appName, appVersion, extraBuildArgs)
}

pipeline {
    agent {
        node {
            label 'linux-amd64-buildx'
        }
    }
    options {
        checkoutToSubdirectory('installer')
    }
    environment {
        CE_APPS = "jumpserver,koko,lina,luna,lion,chen"
        EE_APPS = "core-xpack,magnus,panda,razor,xrdp,video-worker"
    }
    stages {
        stage('Preparation') {
            steps {
                script {
                    env.branch = params.branch
                    if (params.release_version != null) {
                        env.release_version = params.release_version
                    } else {
                        env.release_version = env.branch
                    }

                    echo "RELEASE_VERSION=${release_version}"
                    echo "BRANCH=${branch}"
                }
            }
        }
        stage('Checkout') {
            steps {
                script {
                    def CEApps = env.CE_APPS.split(',')
                    def EEApps = env.EE_APPS.split(',')
                    def apps = env.build_ee ? CEApps + EEApps : CEApps

                    apps.each { app ->
                        dir(app) {
                            checkout([
                                $class: 'GitSCM',
                                branches: [[name: "dev"]],
                                userRemoteConfigs: [[url: "git@github.com:jumpserver/${app}.git"]]
                            ])
                        }
                    }
                }
            }
        }
        stage('Build CE Apps') {
            steps {
                script {
                    def CEApps = env.CE_APPS.split(',')
                    def ceStages = [:]
                    CEApps.each { app ->
                        ceStages["Build ${app}"] = {
                            dir(app) {
                                script {
                                    buildImage(app, env.release_version)
                                }
                            }
                        }
                    }
                    parallel ceStages
                }
            }
        }
        stage('Done') {
            steps {
                echo "All done!"
            }
        }
    }
}


pipeline {
    agent {
        node {
            label 'linux-amd64-buildx'
        }
    }
    options {
        checkoutToSubdirectory('docker-web')
    }
    stages {
        stage('Preparation') {
            steps {
                script {
                    if (params.branch != null) {
                        env.BRANCH_NAME = params.branch
                    }
                    if (params.release_version != null) {
                        env.RELEASE_VERSION = params.release_version
                    } else {
                        env.RELEASE_VERSION = env.BRANCH_NAME
                    }

                    echo "RELEASE_VERSION=${RELEASE_VERSION}"
                    echo "BRANCH=${BRANCH_NAME}"
                }
            }
        }
        stage('Checkout') {
            steps {
                // Get some code from a GitHub repository
                dir('lina') {
                    git url: 'git@github.com:jumpserver/lina.git', branch: "dev"
                }
                dir('luna') {
                    git url: 'git@github.com:jumpserver/luna.git', branch: "dev"
                }
                sh """
                    git config --global user.email "fit2bot@jumpserver.org"
                    git config --global user.name "fit2bot"
                """
            }
        }
        stage('Build repos') {
            parallel {
                stage('lina') {
                    steps {
                        dir('lina') {
                            script {
                                echo "Start build lina"
                                runShellCommand("""
                                    docker buildx build \
                                    --platform linux/amd64,linux/arm64 \
                                    --build-arg VERSION=$RELEASE_VERSION \
                                    -t jumpserver/lina:${RELEASE_VERSION} .
                                """)
                            }
                        }
                    }
                }
                stage('luna') {
                    steps {
                        dir('luna') {
                            script {
                                echo "Start build luna"
                                runShellCommand("""
                                    docker buildx build \
                                    --platform linux/amd64,linux/arm64 \
                                    --build-arg VERSION=$RELEASE_VERSION \
                                    -t jumpserver/luna:${RELEASE_VERSION} .
                                """)
                            }
                        }
                    }
                }
            }
        }
        stage('Build docker web ce') {
            steps {
                script {
                    echo "Start build docker-web"
                    runShellCommand("""
                        docker buildx build \
                        --platform linux/amd64,linux/arm64 \
                        --build-arg VERSION=$RELEASE_VERSION \
                        -t jumpserver/web:${RELEASE_VERSION}-ce \
                        --push .
                    """)
                }
            }
        }
        stage('Build docker web ee') {
            steps {
                script {
                    echo "Start build docker-web"
                    runShellCommand("""
                        docker buildx build \
                        --platform linux/amd64,linux/arm64 \
                        --build-arg VERSION=$RELEASE_VERSION \
                        -f Dockerfile-ee \
                        -t jumpserver/web:${RELEASE_VERSION}-ee \
                        --push .
                    """)
                }
            }
        }
        stage('Done') {
            steps {
                echo "All done!"
            }
        }
    }
}
