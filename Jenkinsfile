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

def tasks = [
        "echo 1",
        "echo 2",
        "echo 3"
]

def other_stages = [
    failFast: true,
    "后端构建": {
        tasks.each { task ->
            stage("build ${task}") {
                sh task
            }
        }
    }
]

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
        CE_APPS = "lion,chen"
        EE_APPS = "core-xpack,magnus,panda,razor,xrdp,video-worker"
    }
    stages {
        stage('Build repos') {
            parallel other_stages
        }
        stage('Done') {
            steps {
                echo "All done!"
            }
        }
    }
}

