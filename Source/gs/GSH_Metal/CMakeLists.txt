include(Header)

project(GSH_Metal)

if(NOT TARGET Framework)
	add_subdirectory(
		${CMAKE_CURRENT_SOURCE_DIR}/../../../deps/Framework/build_cmake/Framework
		${CMAKE_CURRENT_BINARY_DIR}/Framework
	)
endif()

set(METAL_SHADER_SOURCE ${CMAKE_CURRENT_SOURCE_DIR}/GSH_MetalShaders.metal)
set(METAL_SHADER_OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/GSH_MetalShaders.metallib)

# Compile Metal shaders to metallib for faster load times
if(IOS)
	# iOS Metal shader compilation
	add_custom_command(
		OUTPUT ${METAL_SHADER_OUTPUT}
		COMMAND xcrun -sdk iphoneos metal -c ${METAL_SHADER_SOURCE} -o ${CMAKE_CURRENT_BINARY_DIR}/GSH_MetalShaders.air
		COMMAND xcrun -sdk iphoneos metallib ${CMAKE_CURRENT_BINARY_DIR}/GSH_MetalShaders.air -o ${METAL_SHADER_OUTPUT}
		DEPENDS ${METAL_SHADER_SOURCE}
		COMMENT "Compiling Metal shaders for iOS"
	)
elseif(APPLE)
	# macOS Metal shader compilation
	add_custom_command(
		OUTPUT ${METAL_SHADER_OUTPUT}
		COMMAND xcrun -sdk macosx metal -c ${METAL_SHADER_SOURCE} -o ${CMAKE_CURRENT_BINARY_DIR}/GSH_MetalShaders.air
		COMMAND xcrun -sdk macosx metallib ${CMAKE_CURRENT_BINARY_DIR}/GSH_MetalShaders.air -o ${METAL_SHADER_OUTPUT}
		DEPENDS ${METAL_SHADER_SOURCE}
		COMMENT "Compiling Metal shaders for macOS"
	)
endif()

# Create a custom target for the metallib
add_custom_target(metal_shaders DEPENDS ${METAL_SHADER_OUTPUT})

add_library(gsh_metal STATIC
	GSH_Metal.mm
	GSH_Metal.h
	GSH_MetalShaders.metal
)

# Ensure shaders are compiled before the library
add_dependencies(gsh_metal metal_shaders)

target_link_libraries(gsh_metal Framework "-framework Metal" "-framework QuartzCore")
target_include_directories(gsh_metal PRIVATE
	${CMAKE_CURRENT_SOURCE_DIR}/..
	${CMAKE_CURRENT_SOURCE_DIR}/../..
)
target_include_directories(gsh_metal PRIVATE
    ${CMAKE_SOURCE_DIR}/Source/app_shared
)

# Copy metallib to app bundle resources (handled by parent project)
