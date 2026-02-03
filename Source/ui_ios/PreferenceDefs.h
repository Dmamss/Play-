#pragma once

#define PREFERENCE_UI_SHOWFPS "ui.showfps"
#define PREFERENCE_UI_SHOWVIRTUALPAD "ui.showvirtualpad"
#define PREFERENCE_UI_VIRTUALPADOPACITY "ui.virtualpadopacity"
#define PREFERENCE_UI_HIDEVIRTUALPAD_CONTROLLER_CONNECTED "ui.virtualpad.hide.when.controller.connected"
#define PREFERENCE_UI_VIRTUALPAD_HAPTICFEEDBACK "ui.virtualpad.hapticfeedback"

#define PREFERENCE_AUDIO_ENABLEOUTPUT "audio.enableoutput"

#define PREFERENCE_VIDEO_GS_HANDLER "video.gshandler"

#define PREFERENCE_VALUE_VIDEO_GS_HANDLER_OPENGL 0
#define PREFERENCE_VALUE_VIDEO_GS_HANDLER_VULKAN 1
#define PREFERENCE_VALUE_VIDEO_GS_HANDLER_METAL 2

#define PREFERENCE_PS2_FRAMESKIP "ps2.frameskip"
#define PREFERENCE_PS2_FRAMESKIP_MAX 5

#define PREFERENCE_AUDIO_HANDLER "audio.handler"
#define PREFERENCE_VALUE_AUDIO_OPENAL 0
#define PREFERENCE_VALUE_AUDIO_COREAUDIO 1

// EE CPU settings
#define PREFERENCE_PS2_EE_CYCLERATE "ps2.ee.cyclerate"
#define PREFERENCE_PS2_EE_CYCLERATE_100 0
#define PREFERENCE_PS2_EE_CYCLERATE_125 1
#define PREFERENCE_PS2_EE_CYCLERATE_150 2
#define PREFERENCE_PS2_EE_CYCLERATE_200 3

// Advanced emulation options
#define PREFERENCE_EMU_RECOMPILER "emu.recompiler"
#define PREFERENCE_VIDEO_GS_COPIES_TO_TEXTURE "video.gs.copies.totexture"
#define PREFERENCE_VIDEO_IGNORE_FORMAT_CHANGES "video.ignoreformatchanges"
#define PREFERENCE_VIDEO_GPU_TEXTURE_DECODE "video.gputexturedecode"
#define PREFERENCE_VIDEO_FAST_DEPTH "video.fastdepth"
#define PREFERENCE_VIDEO_IMMEDIATE_PRESENT "video.immediatepresent"
#define PREFERENCE_VIDEO_ASYNC_SHADERS "video.asyncshaders"

// Advanced performance options (DolphiniOS-style)
#define PREFERENCE_VIDEO_EFB_ACCESS "video.efb.access"
#define PREFERENCE_VIDEO_TEXTURE_CACHE "video.texturecache"
#define PREFERENCE_VIDEO_GPU_SYNC "video.gpusync"

// Metal renderer options
#define PREFERENCE_VIDEO_METAL_ACCURATE_BLENDING "video.metal.accurateblending"

#define PREFERENCE_ALTSTORE_JIT_ENABLED "altstore.jit.enabled"
// iOS 26+ StikDebug JIT activation
#define PREFERENCE_STIKDEBUG_JIT_ENABLED "stikdebug.jit.enabled"
