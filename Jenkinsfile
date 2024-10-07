pipeline {
    agent { label 'linux' }

    options {
        buildDiscarder(logRotator(artifactDaysToKeepStr: '30', artifactNumToKeepStr: '10'))
    }

    environment {
        PSIPHON_CONFIG = 'op://Jenkins/Conduit Psiphon Config/android_psiphon_config'
        EMBEDDED_SERVER_ENTRIES = 'op://Jenkins/Conduit Psiphon Config/android_embedded_server_entries'
        ANDROID_UPLOAD_KEYSTORE = 'op://Jenkins/Conduit Upload Signing Key/upload-keystore.jks.base64'
        ANDROID_UPLOAD_KEYSTORE_PROPERTIES = 'op://Jenkins/Conduit Upload Signing Key/keystore.properties'
    }

    stages {
        stage('Android build APK') {
            when {
                branch 'main'; 
            }

            steps {

                sh 'npm ci'

                writeFile file: 'src/git-hash.js', text: "export const GIT_HASH = '${env.GIT_COMMIT}';"

                dir('android') {
                    withSecrets() {
                        writeFile file: 'app/src/main/res/raw/psiphon_config', text: env.PSIPHON_CONFIG
                        writeFile file: 'app/src/main/res/raw/embedded_server_entries', text: env.EMBEDDED_SERVER_ENTRIES
                        writeFile file: 'app/upload-keystore.jks', text: env.ANDROID_UPLOAD_KEYSTORE, encoding: "Base64"
                        writeFile file: 'keystore.properties', text: env.ANDROID_UPLOAD_KEYSTORE_PROPERTIES
                    }

                    sh './gradlew clean assembleRelease'

                    sh "mv app/build/outputs/apk/release/app-release.apk app/build/outputs/apk/release/conduit-${env.GIT_COMMIT}.apk"
                }

                archiveArtifacts artifacts: 'android/app/build/outputs/apk/release/*.apk', fingerprint: true, onlyIfSuccessful: true

            }
        }

        stage('Android bundle AAB') {
            when {
                tag "release-*";
            }
            

            steps {

                sh 'npm ci'
               
                script {
                    releaseName = TAG_NAME.minus("release-")
                }

                writeFile file: 'src/git-hash.js', text: "export const GIT_HASH = '${releaseName}';"

                dir('android') {

                    withSecrets() {
                        writeFile file: 'app/src/main/res/raw/psiphon_config', text: env.PSIPHON_CONFIG
                        writeFile file: 'app/src/main/res/raw/embedded_server_entries', text: env.EMBEDDED_SERVER_ENTRIES
                        writeFile file: 'app/upload-keystore.jks', text: env.ANDROID_UPLOAD_KEYSTORE, encoding: "Base64"
                        writeFile file: 'keystore.properties', text: env.ANDROID_UPLOAD_KEYSTORE_PROPERTIES
                    }

                    sh './gradlew clean bundleRelease'

                    sh "mv app/build/outputs/bundle/release/app-release.aab app/build/outputs/bundle/release/conduit-${releaseName}.aab"
                }

                archiveArtifacts artifacts: 'android/app/build/outputs/bundle/release/*.aab', fingerprint: true, onlyIfSuccessful: true

            }
        }
    }

    post {
        always {
            dir('client') {
                // This is very large, save space on jenkins
                sh 'rm -rf node_modules'
            }
        }
        failure {
            script {
                changes = getChangeList()
            }
            slackSend message:"${env.JOB_NAME} - Build #${env.BUILD_NUMBER} failed (<${env.BUILD_URL}|Open>)\nChanges:\n${changes}",
                      color: "danger"
        }
    }
}

String getChangeList() {
    if (currentBuild.changeSets.size() == 0) {
        return "No changes"
    }

    def changeList = ""
    for (changeSet in currentBuild.changeSets) {
        for (entry in changeSet.items) {
            changeList += "- ${entry.msg} [${entry.authorName}]\n"
        }
    }

    return changeList
}