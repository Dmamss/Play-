include(Header)

project(SH_CoreAudio)

if(NOT TARGET Framework)
	add_subdirectory(
		${CMAKE_CURRENT_SOURCE_DIR}/../../../deps/Framework/build_cmake/Framework
		${CMAKE_CURRENT_BINARY_DIR}/Framework
	)
endif()

add_library(sh_coreaudio STATIC
	SH_CoreAudio.mm
	SH_CoreAudio.h
)
target_link_libraries(sh_coreaudio Framework "-framework AudioToolbox" "-framework CoreAudio")
