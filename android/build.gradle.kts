allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// flutter_bluetooth_serialのnamespaceエラーを解決するための設定
subprojects {
    plugins.withId("com.android.library") {
        configure<com.android.build.gradle.LibraryExtension> {
            if (namespace == null) {
                namespace = project.group?.toString() ?: "com.example.${project.name}"
            }
        }
    }
    plugins.withId("com.android.application") {
        configure<com.android.build.gradle.AppExtension> {
            if (namespace == null) {
                namespace = project.group?.toString() ?: "com.example.${project.name}"
            }
        }
    }
}

// flutter_bluetooth_serial等の古いプラグインが compileSdk < 31 のままだと
// androidx.core の android:attr/lStar 解決に失敗するため、31未満なら引き上げる
subprojects {
    afterEvaluate {
        extensions.findByType<com.android.build.gradle.LibraryExtension>()?.apply {
            if ((compileSdk ?: 0) < 31) {
                compileSdk = 35
            }
        }
    }
}

// AGP 9 と android.builtInKotlin=false（Flutter テンプレの opt-out）の間の橋渡し。
// 「AGP 9 なら Kotlin は組み込み」と決め打ちして KGP を当てないプラグイン（device_info_plus 13 など。
// android_file_picker のように property を見るものは自分で当てる）は、opt-out 中は Kotlin が一切
// コンパイルされず GeneratedPluginRegistrant がクラスを見つけられない。Kotlin ソースを持つのに
// KGP が無いライブラリにこちらから当てる。builtInKotlin を true にしたら不要になる
subprojects {
    plugins.withId("com.android.library") {
        val builtIn = (findProperty("android.builtInKotlin") as String?)?.toBoolean() ?: true
        val hasKotlinSources = file("src/main/kotlin").exists()
        if (!builtIn && hasKotlinSources && !plugins.hasPlugin("org.jetbrains.kotlin.android")) {
            logger.lifecycle("[kokage] apply org.jetbrains.kotlin.android to :${project.name} (builtInKotlin=false)")
            apply(plugin = "org.jetbrains.kotlin.android")
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
