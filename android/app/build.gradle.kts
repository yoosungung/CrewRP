plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "app.crewrp"
    compileSdk = 35

    defaultConfig {
        applicationId = "app.crewrp"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
        buildConfigField("String", "GITHUB_CLIENT_ID", "\"Ov23liNLwX1Qg3XOhdQw\"")
        buildConfigField("String", "AUTH_BRIDGE_URL", "\"https://crewrp-auth-bridge.candydate.workers.dev\"")
        buildConfigField("String", "PUSH_BRIDGE_URL", "\"https://crewrp-push-bridge.candydate.workers.dev\"")
        buildConfigField("String", "DISCORD_SERVER_ID", "\"REPLACE_ME\"")
        buildConfigField("String", "DISCORD_CHANNEL_ID", "\"REPLACE_ME\"")
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation(project(":crewrp-core"))
    implementation(platform("androidx.compose:compose-bom:2025.03.00"))
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.browser:browser:1.8.0")
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
}
