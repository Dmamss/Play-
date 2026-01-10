# Guide de Dépannage Build iOS

## 🔧 Solutions aux Problèmes de Build GitHub Actions

### Problème : Exit Code 65 (Build Failed)

Exit code 65 dans GitHub Actions iOS peut avoir plusieurs causes :

#### Solution 1 : Vérifier la Branche
✅ **Fix appliqué** : Le workflow utilise maintenant `GITHUB_REF_NAME` pour détecter correctement les branches `claude/*` et skip l'auto-push de formatage.

**Commit** : `53ea21a` - "fix(ci): Use GITHUB_REF_NAME for branch detection"

#### Solution 2 : Vérifier les Logs Complets
1. Aller sur : https://github.com/Dmamss/Play-/actions
2. Cliquer sur le build qui a échoué
3. Cliquer sur "run_clangformat" ou "build_ios"
4. Développer chaque step pour voir les erreurs détaillées

#### Solution 3 : Build Local (Si GitHub Actions Continue d'Échouer)

Si le build automatique ne fonctionne pas, vous pouvez compiler localement sur un Mac :

```bash
# Prérequis : macOS + Xcode 16.4+

# 1. Installer Vulkan SDK
# Télécharger depuis: https://vulkan.lunarg.com/sdk/home
# Version: 1.4.309.0
# Composant: iOS

# 2. Cloner le repo
git clone --recurse-submodules https://github.com/Dmamss/Play-.git
cd Play-
git checkout claude/fix-build-failure-HmZIL

# 3. Configurer CMake
mkdir build && cd build
export VULKAN_SDK="$HOME/VulkanSDK/1.4.309.0/iOS"

cmake .. \
  -G "Xcode" \
  -DCMAKE_TOOLCHAIN_FILE=../deps/Dependencies/cmake-ios/ios.cmake \
  -DTARGET_IOS=ON \
  -DCMAKE_PREFIX_PATH=$VULKAN_SDK \
  -DBUILD_PSFPLAYER=ON \
  -DBUILD_LIBRETRO_CORE=yes

# 4. Compiler
cmake --build . --config Release

# 5. Ouvrir dans Xcode (optionnel)
open Play.xcodeproj

# 6. Signer l'app
cd build
codesign -s "-" Source/ui_ios/Release-iphoneos/Play.app
# Ou dans Xcode : Sélectionner votre équipe de développement

# 7. Générer l'IPA
cd ../installer_ios
./build_ipa.sh
```

**Résultat** : `Play.ipa` dans le dossier `installer_ios/`

---

## ⚙️ Comprendre le Workflow iOS

### Étapes du Build

1. **run_clangformat** (Ubuntu)
   - Formate le code avec clang-format-16
   - Commit automatique si des changements
   - **Skip push sur branches claude/*** (fix appliqué)
   - Fallback gracieux si push échoue

2. **build_ios** (macOS-latest)
   - Install Xcode 16.4
   - Install Vulkan SDK 1.4.309.0
   - Checkout code + submodules
   - Generate Xcode project via CMake
   - Compile en Release
   - Sign avec ad-hoc signature
   - Generate IPA
   - Upload artifacts

### Paramètres CMake Importants

```cmake
-G "Xcode"                    # Générateur Xcode
-DCMAKE_TOOLCHAIN_FILE=...    # Toolchain iOS
-DTARGET_IOS=ON               # Target iOS explicite
-DCMAKE_PREFIX_PATH=$VULKAN_SDK  # Chemin Vulkan
-DBUILD_PSFPLAYER=ON          # PSF Player activé
-DBUILD_LIBRETRO_CORE=yes     # LibRetro core activé
```

### Toolchain iOS (`ios.cmake`)

```cmake
IPHONEOS_DEPLOYMENT_TARGET = 12.2
CODE_SIGNING_REQUIRED = NO
CODE_SIGNING_ALLOWED = NO
IOS_PLATFORM = OS (device, pas simulator)
```

---

## 🐛 Erreurs Courantes et Solutions

### Erreur : "Could not find Vulkan"

**Cause** : Le Vulkan SDK n'est pas dans CMAKE_PREFIX_PATH

**Solution** :
```bash
# Vérifier que VULKAN_SDK est défini
echo $VULKAN_SDK

# Doit pointer vers : /Users/runner/VulkanSDK/1.4.309.0/iOS
# Ou localement : $HOME/VulkanSDK/1.4.309.0/iOS
```

### Erreur : "Submodule 'deps/...' not initialized"

**Cause** : Submodules non récupérés

**Solution** :
```bash
git submodule update --init --recursive
```

### Erreur : "No such file or directory: Info.plist"

**Cause** : CMake n'a pas trouvé le template Info.plist.in

**Solution** :
```bash
# Vérifier que le fichier existe
ls -la Source/ui_ios/Info.plist.in

# Si manquant, re-clone le repo
```

### Erreur : "codesign failed with exit code 1"

**Cause** : Problème de signature

**Solution 1** : Build sans signer
```bash
# Commenter la ligne codesign dans le workflow
# ou dans votre build local, skip cette étape
```

**Solution 2** : Utiliser votre propre certificat
```bash
# Remplacer "-" par votre identité
codesign -s "iPhone Developer: VotreNom" Play.app
```

### Erreur : "architecture arm64 not supported"

**Cause** : Compilation pour mauvaise architecture

**Solution** :
```bash
# Vérifier que IOS_PLATFORM = OS (pas SIMULATOR)
grep IOS_PLATFORM deps/Dependencies/cmake-ios/ios.cmake
```

---

## 📊 Monitoring du Build

### GitHub Actions Status Badge

Ajoutez ce badge à votre README pour voir le statut en un coup d'œil :

```markdown
[![Build iOS](https://github.com/Dmamss/Play-/actions/workflows/Build%20iOS%2026.yaml/badge.svg)](https://github.com/Dmamss/Play-/actions/workflows/Build%20iOS%2026.yaml)
```

### Notifications

GitHub peut vous notifier par email quand un build échoue :
1. Settings → Notifications
2. GitHub Actions → Cocher "Email"

---

## 🔍 Debug Avancé

### Ajouter Plus de Logging au Workflow

Modifiez `.github/workflows/Build iOS 26.yaml` :

```yaml
- name: Build
  run: |
    cd build
    # Mode verbose pour cmake
    cmake --build . --config Release --verbose

    # Afficher la structure du build
    find Source/ui_ios/Release-iphoneos -type f

    # Vérifier l'app
    ls -lah Source/ui_ios/Release-iphoneos/Play.app

    codesign -s "-" Source/ui_ios/Release-iphoneos/Play.app
```

### Activer Continue-on-Error

Pour voir jusqu'où le build va même en cas d'erreur :

```yaml
- name: Build
  continue-on-error: true
  run: |
    cd build
    cmake --build . --config Release
```

---

## 🎯 Checklist de Diagnostic

Avant de demander de l'aide, vérifiez :

- [ ] Les submodules sont tous initialisés (`git submodule status`)
- [ ] Le commit le plus récent est bien sur la branche
- [ ] Le workflow file a les dernières modifications
- [ ] Les logs GitHub Actions sont accessibles (pas d'erreur de chargement)
- [ ] Le Vulkan SDK est bien téléchargé (voir logs)
- [ ] CMake génère le projet Xcode sans erreur
- [ ] La compilation échoue à quelle étape exactement ?

---

## 📞 Obtenir de l'Aide

Si le problème persiste :

1. **Copier les logs d'erreur complets** depuis GitHub Actions
2. **Noter le commit SHA** qui a échoué
3. **Identifier l'étape exacte** qui échoue
4. **Créer une issue** sur GitHub avec ces informations

---

## ✅ État Actuel

**Dernier fix appliqué** :
- Commit `53ea21a` : Utilisation de `GITHUB_REF_NAME` pour détecter les branches
- Ce fix devrait résoudre l'exit code 65 lié au formatage auto-push

**Prochain build** :
- Devrait automatiquement skip l'auto-push sur `claude/fix-build-failure-HmZIL`
- Continuer avec le build iOS normalement
- Générer Play.ipa avec succès ✅

**Vérifier le statut** : https://github.com/Dmamss/Play-/actions
