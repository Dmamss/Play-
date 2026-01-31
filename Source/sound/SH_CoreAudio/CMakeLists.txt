include(Header)

project(SH_CoreAudio)

add_library(sh_coreaudio STATIC
	SH_CoreAudio.mm
	SH_CoreAudio.h
)
target_link_libraries(sh_coreaudio "-framework AudioToolbox" "-framework CoreAudio")
