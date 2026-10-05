# iPadOS platform layer (WiiPad) + CemuCore static library.
#
# WiiPadPlatform: the iOS implementations of what the desktop GUI normally provides
#   - IOSWindowSystem.mm  : gui/interface/WindowSystem.h
#   - MetalLayerUIKit.mm  : CreateMetalLayer() (macOS: Renderer/Metal/MetalLayer.mm)
#   - CemuBridge.mm       : the only API the SwiftUI app uses (CemuBridge.h is plain Objective-C)
#   - WiiPadLog.mm        : crash-safe file log in the app's Documents folder
#   - WiiPadTouchController.cpp : on-screen controls as a Cemu input device for the emulated GamePad (VPAD)
#   - IOSAudioAPI.mm      : IAudioAPI backend (RemoteIO AudioUnit), registered in audio/IAudioAPI.cpp
#   - ../main.cpp         : provides CemuCommonInit(); its desktop main() is excluded on iOS
#
# CemuCore: every Cemu library plus the vcpkg dependencies merged into one libCemuCore.a,
# which the Xcode app (app/WiiPad) links as a single static library.

add_library(WiiPadPlatform STATIC
	../main.cpp
	CemuBridge.h
	CemuBridge.mm
	IOSWindowSystem.mm
	IOSAudioAPI.h
	IOSAudioAPI.mm
	MetalLayerUIKit.mm
	WiiPadLog.h
	WiiPadLog.mm
	WiiPadTouchController.h
	WiiPadTouchController.cpp
	WiiPadDiagnostics.h
	WiiPadDiagnostics.mm
)

cemu_use_precompiled_header(WiiPadPlatform)

target_compile_options(WiiPadPlatform PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)

target_include_directories(WiiPadPlatform PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")

target_link_libraries(WiiPadPlatform PRIVATE
	CemuAudio
	CemuCafe
	CemuCommon
	CemuComponents
	CemuConfig
	CemuGui
	CemuInput
	CemuUtil
	imguiImpl
)

# --- CemuCore: merge all static libraries into one archive -------------------------------------

set(CEMU_CORE_TARGETS
	WiiPadPlatform
	CemuAudio
	CemuCafe
	CemuCommon
	CemuComponents
	CemuConfig
	CemuInput
	CemuResource
	CemuUtil
	imguiImpl
	ih264d
	zarchive
)
if (TARGET xbyak_aarch64)
	list(APPEND CEMU_CORE_TARGETS xbyak_aarch64)
endif()

set(CEMU_CORE_TARGET_FILES "")
foreach(t ${CEMU_CORE_TARGETS})
	list(APPEND CEMU_CORE_TARGET_FILES "$<TARGET_FILE:${t}>")
endforeach()

# vcpkg installs the dependencies (manifest mode) during configure, so they can be listed now.
if (NOT DEFINED VCPKG_INSTALLED_DIR OR NOT DEFINED VCPKG_TARGET_TRIPLET)
	message(FATAL_ERROR "CemuCore for iOS expects the vcpkg toolchain (VCPKG_INSTALLED_DIR / VCPKG_TARGET_TRIPLET)")
endif()
file(GLOB CEMU_CORE_VCPKG_LIBS "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/lib/*.a")
list(LENGTH CEMU_CORE_VCPKG_LIBS CEMU_CORE_VCPKG_LIB_COUNT)
message(STATUS "CemuCore: merging ${CEMU_CORE_VCPKG_LIB_COUNT} vcpkg static libraries")
foreach(lib ${CEMU_CORE_VCPKG_LIBS})
	message(STATUS "  ${lib}")
endforeach()

set(CEMU_CORE_DIR "${CMAKE_BINARY_DIR}/CemuCore")
set(CEMU_CORE_OUTPUT "${CEMU_CORE_DIR}/libCemuCore.a")

add_custom_command(
	OUTPUT "${CEMU_CORE_OUTPUT}"
	COMMAND ${CMAKE_COMMAND} -E make_directory "${CEMU_CORE_DIR}"
	COMMAND ${CMAKE_COMMAND} -E rm -f "${CEMU_CORE_OUTPUT}"
	COMMAND xcrun libtool -static -no_warning_for_no_symbols -o "${CEMU_CORE_OUTPUT}" ${CEMU_CORE_TARGET_FILES} ${CEMU_CORE_VCPKG_LIBS}
	COMMAND ${CMAKE_COMMAND} -E copy_if_different "${CMAKE_CURRENT_SOURCE_DIR}/CemuBridge.h" "${CEMU_CORE_DIR}/include/CemuBridge.h"
	DEPENDS ${CEMU_CORE_TARGETS} ${CEMU_CORE_VCPKG_LIBS}
	COMMENT "Merging Cemu + dependencies into libCemuCore.a"
	VERBATIM
	COMMAND_EXPAND_LISTS
)
add_custom_target(CemuCore ALL DEPENDS "${CEMU_CORE_OUTPUT}")
