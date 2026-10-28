allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Agora/AndroidX AARs need a modern compileSdk; the Flutter plugins read it
// from the root project's extra properties (safeExtGet).
extra["compileSdkVersion"] = 37

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

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
