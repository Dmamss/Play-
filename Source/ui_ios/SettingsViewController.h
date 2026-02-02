#import <UIKit/UIKit.h>

@interface SettingsViewController : UITableViewController
{
	IBOutlet UISwitch* showFpsSwitch;
	IBOutlet UISwitch* showVirtualPadSwitch;
	IBOutlet UISlider* virtualPadOpacitySlider;
	IBOutlet UISwitch* hideVirtualPadWhenControllerConnected;
	IBOutlet UISwitch* virtualPadHapticFeedbackSwitch;

	IBOutlet UILabel* gsHandlerName;
	IBOutlet UILabel* resolutionFactor;
	IBOutlet UISwitch* resizeOutputToWidescreen;
	IBOutlet UISwitch* forceBilinearFiltering;
	IBOutlet UISwitch* gsRamReadsSwitch;

	IBOutlet UISwitch* limitFrameRateSwitch;
	IBOutlet UILabel* frameskipLabel;

	IBOutlet UISwitch* enableAudioOutput;
	IBOutlet UILabel* audioHandlerName;

	IBOutlet UISwitch* efbAccessSwitch;
	IBOutlet UISwitch* textureCacheSwitch;
	IBOutlet UISwitch* gpuSyncSwitch;

	// Advanced Emulation
	IBOutlet UILabel* eeCycleRateLabel;
	IBOutlet UISwitch* recompilerSwitch;
	IBOutlet UISwitch* gsCopiesTextureSwitch;
	IBOutlet UISwitch* ignoreFormatChangesSwitch;
	IBOutlet UISwitch* gpuTextureDecodeSwitch;
	IBOutlet UISwitch* fastDepthSwitch;
	IBOutlet UISwitch* immediatePresentSwitch;
	IBOutlet UISwitch* asyncShadersSwitch;

	IBOutlet UISwitch* enableAltServerJIT;

	IBOutlet UILabel* versionInfoLabel;
}

@property bool allowGsHandlerSelection;
@property bool allowFullDeviceScan;
@property(copy, nonatomic) void (^completionHandler)(bool);

//Internal: This is set when the user presses the Full Device Scan button.
@property bool fullDeviceScanRequested;

- (IBAction)selectedGsHandler:(UIStoryboardSegue*)segue;
- (IBAction)selectedResolutionFactor:(UIStoryboardSegue*)segue;
- (IBAction)selectedFrameskip:(UIStoryboardSegue*)segue;
- (IBAction)selectedAudioHandler:(UIStoryboardSegue*)segue;
- (IBAction)selectedEeCycleRate:(UIStoryboardSegue*)segue;
- (IBAction)startFullDeviceScan;
- (IBAction)returnToParent;

@end
