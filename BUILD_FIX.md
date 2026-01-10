# Build Fix Documentation

## Problem
The build was failing due to missing dependencies and improperly initialized git submodules.

## Root Causes

### 1. Git Submodules Not Properly Checked Out
The git submodules were initialized but not checked out. Several submodules (Framework, Nuanceur, libchdr) only contained a `.git` file but no actual source files.

Additionally, some submodules had all their files staged for deletion, causing them to appear empty.

### 2. Missing System Dependencies
The following system packages were missing:
- OpenGL development libraries (`libgl1-mesa-dev`, `libglu1-mesa-dev`)
- GLEW library (`libglew-dev`)
- OpenAL library (`libopenal-dev`)
- Qt5 development packages (`qtbase5-dev`, `qttools5-dev`, `qtmultimedia5-dev`)
- Qt5 X11 Extras (`libqt5x11extras5-dev`)

## Solution

### Step 1: Fix Git Submodules
```bash
# Navigate to each corrupted submodule and reset it
cd deps/Framework
git reset --hard HEAD

cd ../Nuanceur
git reset --hard HEAD

cd ../libchdr
git reset --hard HEAD

# Then update all submodules recursively
cd /home/user/Play-
git submodule update --init --recursive
```

### Step 2: Install System Dependencies
```bash
# Install OpenGL and GLEW
apt-get install -y libgl1-mesa-dev libglu1-mesa-dev libglew-dev

# Install OpenAL
apt-get install -y libopenal-dev

# Install Qt5
apt-get install -y qtbase5-dev qttools5-dev qtmultimedia5-dev libqt5x11extras5-dev
```

### Step 3: Build the Project
```bash
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)
```

## Build Result
The build completed successfully with only minor warnings:
- Multi-character character constant warnings in `InputProviderQtKey.cpp` and `InputProviderQtMouse.cpp`
- Qt/GLEW compatibility warnings in `GSH_OpenGLQt.cpp`
- Friend declaration warnings in Nuanceur library

The final executable was built at: `build/Source/ui_qt/Play` (9.5MB, x86-64 ELF executable)

## Note for Future Builds
When cloning this repository, always run:
```bash
git clone --recurse-submodules <repository-url>
```

Or if already cloned:
```bash
git submodule update --init --recursive
```
