plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.mrhakan.ftportal"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.mrhakan.ftportal"
        minSdk = 26
        targetSdk = 35
        versionCode = 4
        versionName = "4.2.1"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // Sideloadable CI build. Replace with a private release signing config for store distribution.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.activity:activity-ktx:1.10.0")
    implementation("androidx.documentfile:documentfile:1.0.1")
    implementation("org.nanohttpd:nanohttpd:2.3.1")
}
