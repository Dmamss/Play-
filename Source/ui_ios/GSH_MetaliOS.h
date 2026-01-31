#pragma once

#import <QuartzCore/QuartzCore.h>
#include "../gs/GSH_Metal/GSH_Metal.h"

class CGSH_MetaliOS : public CGSH_Metal
{
public:
	CGSH_MetaliOS(CAMetalLayer*);
	virtual ~CGSH_MetaliOS() = default;

	static FactoryFunction GetFactoryFunction(CAMetalLayer*);

	void InitializeImpl() override;
	void PresentBackbuffer() override;

private:
	CAMetalLayer* m_layer = nullptr;
};
