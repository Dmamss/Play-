#!/bin/bash
set -e

# Create IPA structure
mkdir -p Payload
rsync -a ../build/Source/ui_ios/Release-iphoneos/Play.app Payload/

# Ensure Frameworks directory exists in the app bundle
mkdir -p Payload/Play.app/Frameworks

# Copy BreakpointJIT framework into the app bundle
cp -r ../deps/BreakpointJIT/BreakpointJIT.framework Payload/Play.app/Frameworks/

# Code sign the framework
codesign -f -s "-" Payload/Play.app/Frameworks/BreakpointJIT.framework

# Create the IPA
zip -r Play.ipa Payload
