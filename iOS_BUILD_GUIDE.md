# Guide de Build iOS pour Play!

## Configuration Requise

### Pour iPhone 12 Pro (A14 Bionic)
- **iOS Version**: iOS 26 compatible
- **Puce**: A14 Bionic (pas de TXM)
- **JIT Support**: Via AltStore/SideStore ou MAP_JIT

> **Note**: L'iPhone 12 Pro n'a pas TXM (Thread Execution Manager). Le TXM est présent uniquement sur A15+ et M2+. Vous utiliserez donc le fallback JIT classique.

---

## Build Automatique via GitHub Actions

Le projet est configuré pour compiler automatiquement via GitHub Actions :

### Processus de Build
1. **Déclenché automatiquement** sur chaque push/PR
2. **Environnement**: macOS-latest avec Xcode 16.4
3. **Vulkan SDK**: Version 1.4.309.0 (téléchargé automatiquement)
4. **Toolchain**: `deps/Dependencies/cmake-ios/ios.cmake`
5. **Output**: Play.ipa + Play.deb

### Télécharger l'IPA
1. Aller sur GitHub → Actions
2. Sélectionner le dernier workflow "Build iOS"
3. Télécharger l'artifact **Play_iOS**
4. Extraire `Play.ipa`

---

## Installation sur iPhone 12 Pro

### Méthode 1 : AltStore (Recommandé)
1. Installer **AltStore** sur votre Mac/PC
2. Connecter votre iPhone en USB
3. Glisser-déposer `Play.ipa` dans AltStore
4. AltStore va signer et installer l'app

### Méthode 2 : SideStore
1. Installer **SideStore** sur votre iPhone
2. Importer `Play.ipa` via WiFi ou AirDrop
3. SideStore va signer et installer

### Méthode 3 : Xcode (Pour développeurs)
1. Ouvrir le projet dans Xcode
2. Connecter votre iPhone
3. Sélectionner votre iPhone comme cible
4. Product → Run

---

## Activation JIT sur iPhone 12 Pro

### Option 1 : AltStore JIT
1. Sur votre iPhone, lancer Play
2. Sur votre Mac/PC avec AltStore Server actif
3. Dans AltStore sur iPhone : **Enable JIT** pour Play
4. Relancer Play

### Option 2 : SideStore JIT
1. Ouvrir SideStore
2. Aller dans les apps installées
3. Appuyer sur Play → **Enable JIT**
4. Relancer Play

> **Note**: Le JIT doit être réactivé à chaque redémarrage de l'app.

---

## Build Local (macOS uniquement)

Si vous voulez compiler localement sur votre Mac :

### Prérequis
```bash
# Xcode 16.4 ou supérieur
xcode-select --install

# Vulkan SDK pour iOS
# Télécharger depuis: https://vulkan.lunarg.com/sdk/home
# Version: 1.4.309.0
```

### Commandes de Build
```bash
# 1. Cloner avec submodules
git clone --recurse-submodules https://github.com/Dmamss/Play-.git
cd Play-

# 2. Créer dossier build
mkdir build && cd build

# 3. Configurer CMake avec toolchain iOS
cmake .. -G"Xcode" \
  -DCMAKE_TOOLCHAIN_FILE=../deps/Dependencies/cmake-ios/ios.cmake \
  -DTARGET_IOS=ON \
  -DCMAKE_PREFIX_PATH=$VULKAN_SDK \
  -DBUILD_PSFPLAYER=ON \
  -DBUILD_LIBRETRO_CORE=yes

# 4. Compiler
cmake --build . --config Release

# 5. Signer l'app (remplacer YOUR_TEAM_ID)
codesign -s "iPhone Developer" \
  --team YOUR_TEAM_ID \
  Source/ui_ios/Release-iphoneos/Play.app

# 6. Générer l'IPA
cd ../installer_ios
./build_ipa.sh
```

L'IPA sera généré dans `installer_ios/Play.ipa`.

---

## Architecture de l'App

### Composants iOS
- **UI**: `Source/ui_ios/` - Interface UIKit
- **JIT Manager**: `Source/ui_ios/PlayJIT.mm`
- **Services JIT**:
  - `StikDebugJitService.mm` - Pour iOS 26+ avec TXM
  - `AltServerJitService.mm` - Pour iOS < 26 ou A14/A13/A12

### Frameworks Embarqués
- **BreakpointJIT.framework** - Support JIT iOS 26+
- **AltKit.framework** - Support AltStore

### Code Généré (JIT)
- **CodeGen ARM64**: `deps/CodeGen/src/Jitter_CodeGen_Arm_64.cpp`
- **MIPS Recompiler**: `Source/MA_MIPSIV.cpp`
- **EE Executor**: `Source/ee/EeExecutor.cpp`

---

## Compatibilité iPhone 12 Pro

| Fonctionnalité | iPhone 12 Pro (A14) | Statut |
|----------------|---------------------|--------|
| **iOS 26** | ✅ Supporté | Compatible |
| **TXM** | ❌ Non disponible | A15+ uniquement |
| **JIT via AltStore** | ✅ Supporté | Recommandé |
| **JIT via SideStore** | ✅ Supporté | Recommandé |
| **MAP_JIT** | ✅ Supporté | Fallback automatique |
| **StikDebug** | ⚠️ Non nécessaire | Pour TXM uniquement |
| **Vulkan** | ✅ Supporté | Via MoltenVK |
| **OpenGL ES** | ✅ Supporté | Rendu par défaut |

---

## Troubleshooting

### L'app crash au lancement
- **Cause**: JIT non activé
- **Solution**: Activer JIT via AltStore ou SideStore

### "Unable to install Play"
- **Cause**: Certificat de signature expiré
- **Solution**: Réinstaller via AltStore (rafraîchit tous les 7 jours)

### Performance lente
- **Cause**: JIT désactivé (mode interpréteur)
- **Solution**: Vérifier que JIT est bien actif

### "App not verified"
- **Cause**: Signature non reconnue par iOS
- **Solution**: Aller dans Réglages → Général → VPN et gestion des appareils → Faire confiance

---

## Workflow GitHub Actions

Le workflow `.github/workflows/Build iOS 26.yaml` :
1. ✅ Formate le code avec clang-format
2. ✅ Compile sur macOS avec Xcode 16.4
3. ✅ Génère Play.ipa
4. ✅ Upload l'IPA comme artifact
5. ✅ (Optionnel) Upload vers S3 si AWS configuré

Pour voir les builds : https://github.com/Dmamss/Play-/actions

---

## Support et Questions

- **Issues**: https://github.com/Dmamss/Play-/issues
- **Workflow iOS**: `.github/workflows/Build iOS 26.yaml`
- **Documentation Build**: `BUILD_FIX.md`
