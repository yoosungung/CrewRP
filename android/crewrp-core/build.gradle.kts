plugins {
    kotlin("jvm")
}

group = "app.crewrp"
version = "0.1.0"

kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation("org.xerial:sqlite-jdbc:3.49.1.0")
    testImplementation(kotlin("test"))
}

tasks.test {
    useJUnitPlatform()
}
