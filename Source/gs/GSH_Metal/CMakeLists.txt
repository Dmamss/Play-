include(Header)

project(GSH_Metal)

if(NOT TARGET PlayCore)
	add_subdirectory(
		${CMAKE_CURRENT_SOURCE_DIR}/../../
		${CMAKE_CURRENT_BINARY_DIR}/Source
	)
endif()

if(NOT TARGET Framework)
	add_subdirectory(
		${CMAKE_CURRENT_SOURCE_DIR}/../../../deps/Framework/build_cmake/Framework
		${CMAKE_CURRENT_BINARY_DIR}/Framework
	)
endif()

add_library(gsh_metal STATIC
	GSH_Metal.mm
	GSH_Metal.h
)
target_link_libraries(gsh_metal PlayCore Framework "-framework Metal" "-framework QuartzCore")
target_include_directories(gsh_metal PRIVATE
	${CMAKE_CURRENT_SOURCE_DIR}/..
	${CMAKE_CURRENT_SOURCE_DIR}/../..
)
