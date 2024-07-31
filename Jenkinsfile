def getDefaultBuildArgs() {
    def buildArgs = ''
    if (env.pullImage == "Yes") {
        buildArgs = '--pull'
    }
    if (env.noCache == "Yes") {
        buildArgs += ' --no-cache'
    }
    if (env.buildARM == "Yes") {
        buildArgs += ' --platform linux/amd64,linux/arm64'
    } else {
        buildArgs += ' --platform linux/amd64'
    }
    return buildArgs
}

def getDefaultPassArgs() {
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


def runShellCommand(script, int retries = 3) {
    for (int i = 0; i < retries; i++) {
        try {
            echo "Running shell command, attempt ${i + 1}..."
            int status = sh(
                    script: script,
                    returnStatus: true
            )
            if (status != 0) {
                throw new Exception("Command failed with status code: ${status}")
            }
            return // 成功时退出函数
        } catch (Exception e) {
            println("Command failed, attempt ${i + 1}, error: ${e}")
            if (i == retries - 1) {
                error("Max retries reached. Failing the build. ${script}")
            }
        }
    }
}



def buildImage(appName, appVersion, String type='CE') {
    // Type  EE, CE, MID, EE-MID
    echo "Building ${appName}:${appVersion}"
    def appBuildOption = [
        "core-xpack": [
            "image": "xpack",
        ],
        "jumpserver": [
            "image": "core"
        ],
        "lina": [
        ],
        "luna": [
            "beforeSh": "rm -rf dist luna"
        ],
        "razor": [
            "buildArgs": "-f docker/Dockerfile"
        ],
        "docker-web": [
            "image": "web"
        ]
    ]
    def buildArgs = getDefaultBuildArgs()
    def passArgs = getDefaultPassArgs()
    buildArgs += " ${passArgs}"

    def buildOption = appBuildOption[appName] ?: [:]

    def image = appName
    if (buildOption.image) {
        image = buildOption.image
    }

    def imageName = "jumpserver/${image}:${appVersion}"
    if (type == "CE") {
        imageName += '-ce'
    } else if (type == "EE") {
        imageName += '-ee'
    }

    def fullName = "${imageName}"
    if (type == "EE" || type == "EE-MID") {
        fullName = "registry.fit2cloud.com/${imageName}"
    }

    // 优先考虑环境变量
    def pushImage = env.pushImage
    if (pushImage == "No") {
        buildArgs += " --load"
    } else {
        buildArgs += " --push"
    }

    if (type == "EE" && fileExists('Dockerfile-ee')) {
        buildArgs += ' -f Dockerfile-ee'
    }

    if (buildOption.buildArgs) {
        buildArgs += " ${buildOption.buildArgs}"
    }

    runShellCommand("docker buildx build ${buildArgs} -t ${fullName} .")
}


def MID_APPS = ["lina", "luna", "core-xpack"]
def CE_APPS = ["jumpserver", "koko", "lion", "chen", "docker-web"]
def EE_APPS = CE_APPS + ["magnus", "panda", "razor", "xrdp", "video-worker"]


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
        build_ee = "Yes"
    }
    stages {
        stage('Preparation') {
            steps {
                script {
                    env.branch = params.branch
                    env.release_version = params.release_version ?: env.branch
                    env.build_args = params.build_args
                }
            }
        }
        stage('Checkout') {
            steps {
                script {
                    def apps = EE_APPS + MID_APPS
                    apps.each { app ->
                        dir(app) {
                            git url: "git@github.com:jumpserver/${app}.git", branch: "${env.branch}"
                        }
                    }
                }
            }
        }
        stage('Build Middle apps') {
            steps {
                script {
                    def ceStages = MID_APPS.collectEntries{ app ->
                        ["Build ${app}": {
                            stage("Build Mid ${app}") {
                                dir(app) {
                                    script {
                                        def type = "MID"
                                        if (app == "core-xpack") {
                                            type = "EE-MID"
                                        }
                                        buildImage(app, env.release_version, type)
                                    }
                                }
                            }
                        }]
                    }
                    parallel ceStages
                }
            }
        }
        stage('Build CE Apps') {
            steps {
                script {
                    def ceStages = CE_APPS.collectEntries{ app ->
                        ["Build ${app}": {
                            stage("Build CE ${app}") {
                                dir(app) {
                                    script {
                                        buildImage(app, env.release_version, "CE")
                                    }
                                }
                            }
                        }]
                    }
                    parallel ceStages
                }
            }
        }
        stage('Build EE Apps') {
            steps {
                script {
                    def ceStages = EE_APPS.collectEntries{ app ->
                        ["Build ${app}": {
                            stage("Build EE ${app}") {
                                dir(app) {
                                    script {
                                        buildImage(app, env.release_version, "EE")
                                    }
                                }
                            }
                        }]
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

