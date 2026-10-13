plugins {
    kotlin("jvm")
    kotlin("plugin.serialization")
}

group = "app.crewrp"
version = "0.1.0"

kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation("org.xerial:sqlite-jdbc:3.49.1.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.8.1")
    implementation("org.json:json:20240303")
    testImplementation(kotlin("test"))
}

tasks.test {
    useJUnitPlatform()
}
