# WiiPad (Cemu iPadOS) dependency triplet: static arm64 libraries for iPadOS, release only.
# Deployment target must match app/WiiPad/project.yml and the CMake configure in ios-build.yml.
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME iOS)
set(VCPKG_OSX_DEPLOYMENT_TARGET "16.0")
set(VCPKG_BUILD_TYPE release)

# The iOS 27 SDK declares pipe2() and accept4() (available from iOS 27.0). curl's configure checks only find the
# symbols, so with the 16.0 deployment target it would call functions older iOS doesn't have (and fails the build
# with -Werror=unguarded-availability). Make curl use its fallbacks.
if(PORT STREQUAL "curl")
    set(VCPKG_CMAKE_CONFIGURE_OPTIONS -DHAVE_PIPE2=0 -DHAVE_ACCEPT4=0)
endif()
