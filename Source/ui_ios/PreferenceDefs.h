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

// Emulation options
#define PREFERENCE_EMU_RECOMPILER "emu.recompiler"

// Metal renderer options
#define PREFERENCE_VIDEO_METAL_ACCURATE_BLENDING "video.metal.accurateblending"
#define PREFERENCE_VIDEO_METAL_PRECOMPILE_SHADERS "video.metal.precompileshaders"

#define PREFERENCE_ALTSTORE_JIT_ENABLED "altstore.jit.enabled"
// iOS 26+ StikDebug JIT activation
#define PREFERENCE_STIKDEBUG_JIT_ENABLED "stikdebug.jit.enabled"
