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

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

subprojects {
    if (name == "telephony") {
        afterEvaluate {
            extensions.findByName("android")?.let { androidExt ->
                val namespaceMethod = androidExt.javaClass.methods.find { it.name == "setNamespace" }
                if (namespaceMethod != null) {
                    namespaceMethod.invoke(androidExt, "com.shounakmulay.telephony")
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
