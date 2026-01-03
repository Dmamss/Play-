cmake_minimum_required(VERSION 3.18)

set(CMAKE_MODULE_PATH
	${CMAKE_CURRENT_SOURCE_DIR}/../../deps/Dependencies/cmake-modules
	${CMAKE_MODULE_PATH}
)
include(Header)

project(PlayUI LANGUAGES C Swift)

set(USE_GSH_VULKAN OFF)
find_package(Vulkan)
if(Vulkan_FOUND)
	set(USE_GSH_VULKAN ON)
	message("Building with Vulkan support.")
else()
	message("Building without Vulkan support. If you want to enable Vulkan, please make sure VULKAN_SDK is set and place its path inside CMAKE_PREFIX_PATH.")
endif()

if(NOT TARGET PlayCore)
	add_subdirectory(
		${CMAKE_CURRENT_SOURCE_DIR}/../
		${CMAKE_CURRENT_BINARY_DIR}/Source
	)
endif()
list(APPEND UI_IOS_PROJECT_LIBS PlayCore)

if(NOT TARGET gsh_opengl)
	add_subdirectory(
		${CMAKE_CURRENT_SOURCE_DIR}/../gs/GSH_OpenGL
		${CMAKE_CURRENT_BINARY_DIR}/gs/GSH_OpenGL
	)
endif()
list(INSERT UI_IOS_PROJECT_LIBS 0 gsh_opengl)

if(USE_GSH_VULKAN)
	if(NOT TARGET gsh_vulkan)
		add_subdirectory(
			${CMAKE_CURRENT_SOURCE_DIR}/../gs/GSH_Vulkan
			${CMAKE_CURRENT_BINARY_DIR}/gs/GSH_Vulkan
		)
	endif()
	list(INSERT UI_IOS_PROJECT_LIBS 0 gsh_vulkan)
	list(APPEND UI_IOS_DEFINITIONS_LIST USE_GSH_VULKAN)
endif()

file(GLOB_RECURSE RESOURCES
	${CMAKE_CURRENT_SOURCE_DIR}/Assets.xcassets/*
	${CMAKE_CURRENT_SOURCE_DIR}/Base.lproj/*
)

set(OSX_SOURCES
	AppDelegate.mm
	GSH_OpenGLiOS.cpp
	iOSJitService.mm
	MainViewController.mm
	OptionsViewController.mm
	PlayViewController.mm
	SettingViewController.mm
	VulkanViewController.mm
	# JIT Support (iOS 26)
	JIT/DualMapping.mm
	JIT/JITManager.mm
)

set(OSX_HEADERS
	AppDelegate.h
	AltServerJitService.h
	iOSJitService.h
	MainViewController.h
	OptionsViewController.h
	PlayViewController.h
	SettingViewController.h
	VulkanViewController.h
	# JIT Support (iOS 26)
	JIT/DualMapping.h
	JIT/JITManager.h
)

add_executable(Play MACOSX_BUNDLE ${OSX_SOURCES} ${OSX_HEADERS} ${RESOURCES})

# Include JIT headers directory
target_include_directories(Play PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/JIT)

set_target_properties(Play PROPERTIES XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET "15.0")
set_target_properties(Play PROPERTIES XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2")
set_target_properties(Play PROPERTIES XCODE_ATTRIBUTE_LD_RUNPATH_SEARCH_PATHS "$(inherited) @executable_path/Frameworks")
set_target_properties(Play PROPERTIES XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "com.virtualapplications.play")
set_target_properties(Play PROPERTIES XCODE_ATTRIBUTE_PRODUCT_NAME "Play")
set_target_properties(Play PROPERTIES XCODE_ATTRIBUTE_ASSETCATALOG_COMPILER_APPICON_NAME "AppIcon")
set_target_properties(Play PROPERTIES XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC "YES")
set_target_properties(Play PROPERTIES XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_WEAK "YES")

# Set the SWIFT_OBJC_BRIDGING_HEADER property
set_target_properties(Play PROPERTIES XCODE_ATTRIBUTE_SWIFT_OBJC_BRIDGING_HEADER "${CMAKE_CURRENT_SOURCE_DIR}/Play-Bridging-Header.h")

target_compile_options(Play PRIVATE $<$<COMPILE_LANGUAGE:Swift>:-x objective-c++ -fobjc-arc>)

# Probably a better way to set the framework link libraries.
target_link_libraries(Play ${UIKIT_LIBRARY})
target_link_libraries(Play ${COREGRAPHICS_LIBRARY})
target_link_libraries(Play ${GAMECONTROLLER_LIBRARY})
target_link_libraries(Play ${QUARTZCORE_LIBRARY})
target_link_libraries(Play ${IMAGEIO_LIBRARY})
target_link_libraries(Play ${UI_IOS_PROJECT_LIBS} "-ObjC -lsqlite3 -framework OpenAL")

target_compile_definitions(Play PRIVATE ${UI_IOS_DEFINITIONS_LIST})

# Set a custom plist file for the app bundle
# NOTE: for these values to be used Info.plist has to be edited
# NOTE: from cmake 3.7.0 you can use %b for month name abbreviations
string(TIMESTAMP DATE "%Y-%m-%d")
set_target_properties(
	Play
	PROPERTIES
		MACOSX_BUNDLE_INFO_STRING "${PROJECT_NAME}"
		MACOSX_BUNDLE_GUI_IDENTIFIER "com.virtualapplications.play"
		MACOSX_BUNDLE_LONG_VERSION_STRING "${PROJECT_NAME} Version ${PROJECT_Version}"
		MACOSX_BUNDLE_BUNDLE_NAME ${PROJECT_NAME}
		MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_Version}"
		MACOSX_BUNDLE_BUNDLE_VERSION ${DATE}
		MACOSX_BUNDLE_COPYRIGHT "© Virtual Applications, 2017"
		MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist"
		XCODE_ATTRIBUTE_ENABLE_USER_SCRIPT_SANDBOXING "NO"
)
