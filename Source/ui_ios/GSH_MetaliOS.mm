#import "GSH_MetaliOS.h"
#import <Metal/Metal.h>

CGSH_MetaliOS::CGSH_MetaliOS(CAMetalLayer* layer)
    : m_layer(layer)
{
}

CGSHandler::FactoryFunction CGSH_MetaliOS::GetFactoryFunction(CAMetalLayer* layer)
{
	return [layer]() { return new CGSH_MetaliOS(layer); };
}

void CGSH_MetaliOS::InitializeImpl()
{
	// Set the layer reference in the parent class
	m_metalLayer = m_layer;

	// Configure the layer
	m_layer.device = MTLCreateSystemDefaultDevice();
	m_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
	m_layer.framebufferOnly = YES;

	// Initialize the Metal backend
	CGSH_Metal::InitializeImpl();

	// Set presentation params from the layer size
	CGSize drawableSize = m_layer.drawableSize;

	PRESENTATION_PARAMS presentationParams;
	presentationParams.mode = PRESENTATION_MODE_FIT;
	presentationParams.windowWidth = drawableSize.width;
	presentationParams.windowHeight = drawableSize.height;

	SetPresentationParams(presentationParams);

	NSLog(@"[GSH_MetaliOS] Initialized with drawable size: %.0f x %.0f", drawableSize.width, drawableSize.height);
}

void CGSH_MetaliOS::PresentBackbuffer()
{
	// Presentation is handled in DoPresent via CAMetalLayer nextDrawable
}
