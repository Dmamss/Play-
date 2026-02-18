#import "SettingsViewController.h"
#import "SettingsListSelectorViewController.h"
#include "AppConfig.h"
#include "PreferenceDefs.h"
#include "../gs/GSHandler.h"
#include "../gs/GSH_OpenGL/GSH_OpenGL.h"
#include "../PS2VM_Preferences.h"

@implementation SettingsViewController

- (void)updateGsHandlerNameLabel
{
	int gsHandlerId = CAppConfig::GetInstance().GetPreferenceInteger(PREFERENCE_VIDEO_GS_HANDLER);
	switch(gsHandlerId)
	{
	default:
		[[fallthrough]];
	case PREFERENCE_VALUE_VIDEO_GS_HANDLER_OPENGL:
		[gsHandlerName setText:@"OpenGL"];
		break;
	case PREFERENCE_VALUE_VIDEO_GS_HANDLER_VULKAN:
		[gsHandlerName setText:@"Vulkan (MoltenVK)"];
		break;
	case PREFERENCE_VALUE_VIDEO_GS_HANDLER_METAL:
		[gsHandlerName setText:@"Metal (Native)"];
		break;
	}
}

- (void)updateAudioHandlerNameLabel
{
	int audioHandlerId = CAppConfig::GetInstance().GetPreferenceInteger(PREFERENCE_AUDIO_HANDLER);
	switch(audioHandlerId)
	{
	default:
		[[fallthrough]];
	case PREFERENCE_VALUE_AUDIO_COREAUDIO:
		[audioHandlerName setText:@"CoreAudio"];
		break;
	case PREFERENCE_VALUE_AUDIO_OPENAL:
		[audioHandlerName setText:@"OpenAL"];
		break;
	}
}

- (void)updateResolutionFactorLabel
{
	int factor = CAppConfig::GetInstance().GetPreferenceInteger(PREF_CGSH_OPENGL_RESOLUTION_FACTOR);
	[resolutionFactor setText:[NSString stringWithFormat:@"%dx", factor]];
}

- (void)updateFrameskipLabel
{
	int skip = CAppConfig::GetInstance().GetPreferenceInteger(PREFERENCE_PS2_FRAMESKIP);
	if(skip <= 0)
		[frameskipLabel setText:@"Off"];
	else
		[frameskipLabel setText:[NSString stringWithFormat:@"%d", skip]];
}

- (void)updateEeCycleRateLabel
{
	int rate = CAppConfig::GetInstance().GetPreferenceInteger(PREFERENCE_PS2_EE_CYCLERATE);
	switch(rate)
	{
	default:
		[[fallthrough]];
	case PREFERENCE_PS2_EE_CYCLERATE_100:
		[eeCycleRateLabel setText:@"100% (Default)"];
		break;
	case PREFERENCE_PS2_EE_CYCLERATE_125:
		[eeCycleRateLabel setText:@"125%"];
		break;
	case PREFERENCE_PS2_EE_CYCLERATE_150:
		[eeCycleRateLabel setText:@"150%"];
		break;
	case PREFERENCE_PS2_EE_CYCLERATE_200:
		[eeCycleRateLabel setText:@"200%"];
		break;
	}
}

- (void)viewDidLoad
{
	[showFpsSwitch setOn:CAppConfig::GetInstance().GetPreferenceBoolean(PREFERENCE_UI_SHOWFPS)];
	[showVirtualPadSwitch setOn:CAppConfig::GetInstance().GetPreferenceBoolean(PREFERENCE_UI_SHOWVIRTUALPAD)];
	[virtualPadOpacitySlider setValue:float(CAppConfig::GetInstance().GetPreferenceInteger(PREFERENCE_UI_VIRTUALPADOPACITY) / 100.0)];
	[hideVirtualPadWhenControllerConnected setOn:CAppConfig::GetInstance().GetPreferenceBoolean(PREFERENCE_UI_HIDEVIRTUALPAD_CONTROLLER_CONNECTED)];
	[virtualPadHapticFeedbackSwitch setOn:CAppConfig::GetInstance().GetPreferenceBoolean(PREFERENCE_UI_VIRTUALPAD_HAPTICFEEDBACK)];

	[self updateGsHandlerNameLabel];
	[self updateResolutionFactorLabel];
	[resizeOutputToWidescreen setOn:CAppConfig::GetInstance().GetPreferenceBoolean(PREF_CGSHANDLER_WIDESCREEN)];
	[forceBilinearFiltering setOn:CAppConfig::GetInstance().GetPreferenceBoolean(PREF_CGSH_OPENGL_FORCEBILINEARTEXTURES)];
	[gsRamReadsSwitch setOn:CAppConfig::GetInstance().GetPreferenceBoolean(PREF_CGSHANDLER_GS_RAM_READS_ENABLED)];

	[limitFrameRateSwitch setOn:CAppConfig::GetInstance().GetPreferenceBoolean(PREF_PS2_LIMIT_FRAMERATE)];
	[self updateFrameskipLabel];

	[enableAudioOutput setOn:CAppConfig::GetInstance().GetPreferenceBoolean(PREFERENCE_AUDIO_ENABLEOUTPUT)];
	[self updateAudioHandlerNameLabel];

	// Emulation options
	[self updateEeCycleRateLabel];
	[recompilerSwitch setOn:CAppConfig::GetInstance().GetPreferenceBoolean(PREFERENCE_EMU_RECOMPILER)];

	[enableAltServerJIT setOn:CAppConfig::GetInstance().GetPreferenceBoolean(PREFERENCE_ALTSTORE_JIT_ENABLED)];

	// Metal renderer options
	[metalAccurateBlendingSwitch setOn:CAppConfig::GetInstance().GetPreferenceBoolean(PREFERENCE_VIDEO_METAL_ACCURATE_BLENDING)];
	[metalPrecompileShadersSwitch setOn:CAppConfig::GetInstance().GetPreferenceBoolean(PREFERENCE_VIDEO_METAL_PRECOMPILE_SHADERS)];

	NSString* versionString = [NSString stringWithFormat:@"%s - %s", PLAY_VERSION, __DATE__];
	versionInfoLabel.text = versionString;
}

- (void)viewDidDisappear:(BOOL)animated
{
	CAppConfig::GetInstance().SetPreferenceBoolean(PREFERENCE_UI_SHOWFPS, showFpsSwitch.isOn);
	CAppConfig::GetInstance().SetPreferenceBoolean(PREFERENCE_UI_SHOWVIRTUALPAD, showVirtualPadSwitch.isOn);
	CAppConfig::GetInstance().SetPreferenceBoolean(PREFERENCE_UI_HIDEVIRTUALPAD_CONTROLLER_CONNECTED, showVirtualPadSwitch.isOn);
	int prefValue = int(virtualPadOpacitySlider.value * 100.0);
	CAppConfig::GetInstance().SetPreferenceInteger(PREFERENCE_UI_VIRTUALPADOPACITY, prefValue);
	CAppConfig::GetInstance().SetPreferenceBoolean(PREFERENCE_UI_VIRTUALPAD_HAPTICFEEDBACK, virtualPadHapticFeedbackSwitch.isOn);

	CAppConfig::GetInstance().SetPreferenceBoolean(PREF_CGSHANDLER_WIDESCREEN, resizeOutputToWidescreen.isOn);
	CAppConfig::GetInstance().SetPreferenceBoolean(PREF_CGSH_OPENGL_FORCEBILINEARTEXTURES, forceBilinearFiltering.isOn);
	CAppConfig::GetInstance().SetPreferenceBoolean(PREF_CGSHANDLER_GS_RAM_READS_ENABLED, gsRamReadsSwitch.isOn);

	CAppConfig::GetInstance().SetPreferenceBoolean(PREF_PS2_LIMIT_FRAMERATE, limitFrameRateSwitch.isOn);

	CAppConfig::GetInstance().SetPreferenceBoolean(PREFERENCE_AUDIO_ENABLEOUTPUT, enableAudioOutput.isOn);

	// Emulation options
	CAppConfig::GetInstance().SetPreferenceBoolean(PREFERENCE_EMU_RECOMPILER, recompilerSwitch.isOn);

	CAppConfig::GetInstance().SetPreferenceBoolean(PREFERENCE_ALTSTORE_JIT_ENABLED, enableAltServerJIT.isOn);

	// Metal renderer options
	CAppConfig::GetInstance().SetPreferenceBoolean(PREFERENCE_VIDEO_METAL_ACCURATE_BLENDING, metalAccurateBlendingSwitch.isOn);
	CAppConfig::GetInstance().SetPreferenceBoolean(PREFERENCE_VIDEO_METAL_PRECOMPILE_SHADERS, metalPrecompileShadersSwitch.isOn);

	CAppConfig::GetInstance().Save();

	if(self.completionHandler)
	{
		self.completionHandler(self.fullDeviceScanRequested);
	}
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath
{
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (BOOL)shouldPerformSegueWithIdentifier:(NSString*)identifier sender:(id)sender
{
	if([identifier isEqualToString:@"showGsHandlerSelector"])
	{
		return self.allowGsHandlerSelection;
	}
	return TRUE;
}

- (void)prepareForSegue:(UIStoryboardSegue*)segue sender:(id)sender
{
	if([segue.identifier isEqualToString:@"showResolutionFactorSelector"])
	{
		SettingsListSelectorViewController* selector = (SettingsListSelectorViewController*)segue.destinationViewController;
		int factor = CAppConfig::GetInstance().GetPreferenceInteger(PREF_CGSH_OPENGL_RESOLUTION_FACTOR);
		selector.value = log2(factor);
	}
	else if([segue.identifier isEqualToString:@"showGsHandlerSelector"])
	{
		SettingsListSelectorViewController* selector = (SettingsListSelectorViewController*)segue.destinationViewController;
		selector.value = CAppConfig::GetInstance().GetPreferenceInteger(PREFERENCE_VIDEO_GS_HANDLER);
	}
	else if([segue.identifier isEqualToString:@"showFrameskipSelector"])
	{
		SettingsListSelectorViewController* selector = (SettingsListSelectorViewController*)segue.destinationViewController;
		selector.value = CAppConfig::GetInstance().GetPreferenceInteger(PREFERENCE_PS2_FRAMESKIP);
	}
	else if([segue.identifier isEqualToString:@"showAudioHandlerSelector"])
	{
		SettingsListSelectorViewController* selector = (SettingsListSelectorViewController*)segue.destinationViewController;
		selector.value = CAppConfig::GetInstance().GetPreferenceInteger(PREFERENCE_AUDIO_HANDLER);
	}
	else if([segue.identifier isEqualToString:@"showEeCycleRateSelector"])
	{
		SettingsListSelectorViewController* selector = (SettingsListSelectorViewController*)segue.destinationViewController;
		selector.value = CAppConfig::GetInstance().GetPreferenceInteger(PREFERENCE_PS2_EE_CYCLERATE);
	}
}

- (IBAction)selectedGsHandler:(UIStoryboardSegue*)segue
{
	SettingsListSelectorViewController* selector = (SettingsListSelectorViewController*)segue.sourceViewController;
	CAppConfig::GetInstance().SetPreferenceInteger(PREFERENCE_VIDEO_GS_HANDLER, selector.value);
	[self updateGsHandlerNameLabel];
}

- (IBAction)selectedResolutionFactor:(UIStoryboardSegue*)segue
{
	SettingsListSelectorViewController* selector = (SettingsListSelectorViewController*)segue.sourceViewController;
	int factor = 1 << selector.value;
	CAppConfig::GetInstance().SetPreferenceInteger(PREF_CGSH_OPENGL_RESOLUTION_FACTOR, factor);
	[self updateResolutionFactorLabel];
}

- (IBAction)selectedFrameskip:(UIStoryboardSegue*)segue
{
	SettingsListSelectorViewController* selector = (SettingsListSelectorViewController*)segue.sourceViewController;
	CAppConfig::GetInstance().SetPreferenceInteger(PREFERENCE_PS2_FRAMESKIP, selector.value);
	[self updateFrameskipLabel];
}

- (IBAction)selectedAudioHandler:(UIStoryboardSegue*)segue
{
	SettingsListSelectorViewController* selector = (SettingsListSelectorViewController*)segue.sourceViewController;
	CAppConfig::GetInstance().SetPreferenceInteger(PREFERENCE_AUDIO_HANDLER, selector.value);
	[self updateAudioHandlerNameLabel];
}

- (IBAction)selectedEeCycleRate:(UIStoryboardSegue*)segue
{
	SettingsListSelectorViewController* selector = (SettingsListSelectorViewController*)segue.sourceViewController;
	CAppConfig::GetInstance().SetPreferenceInteger(PREFERENCE_PS2_EE_CYCLERATE, selector.value);
	[self updateEeCycleRateLabel];
}

- (IBAction)startFullDeviceScan
{
	if(!self.allowFullDeviceScan) return;
	self.fullDeviceScanRequested = true;
	[self.presentingViewController dismissViewControllerAnimated:YES completion:nil];
}

- (IBAction)returnToParent
{
	[self.presentingViewController dismissViewControllerAnimated:YES completion:nil];
}

@end
