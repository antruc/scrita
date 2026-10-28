allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

// setup.sh: force compileSdk
subprojects {
    val forceCompileSdk: Project.() -> Unit = {
        if (plugins.hasPlugin("com.android.library")) {
            extensions.findByName("android")?.let { ext ->
                ext.javaClass.getMethod("setCompileSdkVersion", String::class.java)
                    .invoke(ext, "android-37.0")
            }
        }
    }
    if (state.executed) forceCompileSdk() else afterEvaluate { forceCompileSdk() }
}

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
