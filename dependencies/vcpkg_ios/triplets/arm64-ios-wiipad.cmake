# WiiPad (Cemu iPadOS) dependency triplet: static arm64 libraries for iPadOS, release only.
# Deployment target must match app/WiiPad/project.yml and the CMake configure in ios-build.yml.
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME iOS)
set(VCPKG_OSX_DEPLOYMENT_TARGET "16.0")
set(VCPKG_BUILD_TYPE release)
