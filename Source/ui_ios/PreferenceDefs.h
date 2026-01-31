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

// Advanced performance options (DolphiniOS-style)
#define PREFERENCE_VIDEO_EFB_ACCESS "video.efb.access"
#define PREFERENCE_VIDEO_TEXTURE_CACHE "video.texturecache"
#define PREFERENCE_VIDEO_GPU_SYNC "video.gpusync"

#define PREFERENCE_ALTSTORE_JIT_ENABLED "altstore.jit.enabled"
// iOS 26+ StikDebug JIT activation
#define PREFERENCE_STIKDEBUG_JIT_ENABLED "stikdebug.jit.enabled"
