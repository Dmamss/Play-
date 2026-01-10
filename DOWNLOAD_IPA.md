# 📱 Comment Télécharger et Installer Play sur iPhone 12 Pro

## ✅ Build en Cours !

Le build iOS a été **automatiquement déclenché** sur GitHub Actions. Voici comment récupérer votre IPA :

---

## 📥 Étape 1 : Télécharger l'IPA

### Option A : Via GitHub Actions (Recommandé)

1. **Aller sur la page Actions** :
   ```
   https://github.com/Dmamss/Play-/actions
   ```

2. **Sélectionner le workflow "Build iOS"** :
   - Cherchez le run le plus récent (commit: `docs: Add comprehensive iOS build guide...`)
   - Cliquez dessus

3. **Attendre la fin du build** :
   - ⏱️ Durée estimée : **10-15 minutes**
   - Le workflow doit être ✅ vert (succès)

4. **Télécharger l'artifact "Play_iOS"** :
   - En bas de la page du workflow
   - Section "Artifacts"
   - Cliquez sur **Play_iOS** pour télécharger

5. **Extraire le ZIP** :
   - Vous obtiendrez :
     - ✅ `Play.ipa` (pour installation via AltStore/SideStore)
     - ✅ `Play.deb` (pour jailbreak)
     - ✅ `Packages.bz2` (metadata Cydia)

### Option B : Via le lien direct (une fois le build terminé)

```
https://github.com/Dmamss/Play-/actions/workflows/Build%20iOS%2026.yaml
```

---

## 📲 Étape 2 : Installer sur iPhone 12 Pro

### Méthode 1 : AltStore (⭐ RECOMMANDÉ)

#### Sur votre ordinateur (Mac/Windows)
1. **Télécharger AltServer** :
   - Mac: https://altstore.io/
   - Windows: https://altstore.io/

2. **Installer AltStore sur iPhone** :
   - Connecter iPhone via USB
   - Lancer AltServer
   - Clic sur icône AltServer → Install AltStore → [Votre iPhone]

#### Sur votre iPhone 12 Pro
3. **Installer Play.ipa** :
   - Ouvrir **AltStore**
   - Onglet "My Apps"
   - Appuyer sur **+** (en haut)
   - Sélectionner **Play.ipa**
   - Attendre l'installation (≈ 2 minutes)

4. **Faire confiance au certificat** :
   - Réglages → Général → VPN et gestion des appareils
   - Cliquer sur votre Apple ID
   - Cliquer **"Faire confiance"**

### Méthode 2 : SideStore

1. **Installer SideStore** :
   - Télécharger depuis : https://sidestore.io/
   - Suivre les instructions d'installation

2. **Importer Play.ipa** :
   - Ouvrir SideStore
   - Importer via AirDrop ou WiFi
   - Installer

---

## 🚀 Étape 3 : Activer le JIT

> **⚠️ IMPORTANT** : Le JIT doit être activé **à chaque lancement** de Play.

### Via AltStore (sur votre ordinateur)

1. **S'assurer qu'AltServer est lancé** sur votre Mac/Windows
2. **iPhone et ordinateur sur le même WiFi**
3. **Sur iPhone** :
   - Ouvrir **AltStore**
   - Onglet "My Apps"
   - Appuyer longuement sur **Play**
   - Sélectionner **"Enable JIT"**
   - Attendre confirmation (≈ 5 secondes)
4. **Lancer Play** immédiatement après

### Via SideStore (sur iPhone uniquement)

1. **Ouvrir SideStore**
2. **Apps installées** → **Play**
3. **Appuyer sur "Enable JIT"**
4. **Lancer Play**

---

## 🎮 Utilisation de Play

### Transfert de ROMs

1. **Via iTunes/Finder** :
   - Connecter iPhone en USB
   - iTunes/Finder → [Votre iPhone] → Partage de fichiers
   - Sélectionner **Play**
   - Glisser-déposer vos fichiers `.iso` ou `.bin/.cue`

2. **Via l'app Play** :
   - Ouvrir Play
   - Aller dans **Settings** → **File Browser**
   - Importer depuis iCloud Drive / Files

### Lancer un jeu

1. Ouvrir **Play**
2. Sélectionner votre jeu dans la liste
3. Appuyer pour lancer
4. Profiter ! 🎮

---

## ⚙️ Spécificités iPhone 12 Pro (A14 Bionic)

| Caractéristique | iPhone 12 Pro | Notes |
|----------------|---------------|-------|
| **Puce** | A14 Bionic | Pas de TXM |
| **iOS Max** | iOS 26 | ✅ Supporté |
| **JIT** | AltStore/MAP_JIT | ⚠️ Pas de StikDebug nécessaire |
| **Performance** | Excellente | 60 FPS pour la plupart des jeux |
| **Écran** | 6.1" Super Retina XDR | Parfait pour PS2 |

### Pourquoi pas de StikDebug ?

- **StikDebug** est uniquement pour iOS 26 avec **TXM** (A15+, M2+)
- **iPhone 12 Pro** a une puce **A14** (pas de TXM)
- Vous utilisez le **fallback JIT classique** (AltStore/MAP_JIT)
- C'est **parfaitement normal** et fonctionne très bien !

---

## 🐛 Troubleshooting

### L'app crash immédiatement
✅ **Solution** : Activer le JIT (voir Étape 3)

### "Unable to Install Play"
✅ **Solution** :
- Supprimer l'ancienne version de Play
- Réinstaller via AltStore
- Vérifier que votre Apple ID est connecté dans AltStore

### L'app disparaît après 7 jours
✅ **Solution** :
- AltStore rafraîchit automatiquement les apps si AltServer est en cours
- Ou : Ouvrir AltStore → "Refresh All"

### Performance lente / Jeu lag
✅ **Vérifications** :
1. JIT est-il activé ? (voir Étape 3)
2. iPhone en mode "Performance" (pas en économie d'énergie)
3. Fermer les autres apps en arrière-plan

### "Enable JIT" ne fonctionne pas
✅ **Solution** :
- AltServer doit être **lancé** sur votre ordinateur
- iPhone et ordinateur sur le **même réseau WiFi**
- Réessayer plusieurs fois (parfois ça prend 2-3 tentatives)

---

## 📊 Statut du Build

### Build en cours
Commit : `8d501e8` - "docs: Add comprehensive iOS build guide for iPhone 12 Pro"

### Vérifier l'état
```
https://github.com/Dmamss/Play-/actions
```

### Que fait le build ?
1. ✅ Formate le code (clang-format)
2. ✅ Compile avec Xcode 16.4 sur macOS
3. ✅ Installe Vulkan SDK 1.4.309.0
4. ✅ Build en configuration Release
5. ✅ Génère Play.ipa
6. ✅ Upload comme artifact GitHub

---

## 📚 Ressources Utiles

- **Guide Build iOS Complet** : `iOS_BUILD_GUIDE.md`
- **Fixes Build** : `BUILD_FIX.md`
- **GitHub Actions** : https://github.com/Dmamss/Play-/actions
- **AltStore** : https://altstore.io/
- **SideStore** : https://sidestore.io/

---

## 🎉 Bon Jeu !

Une fois l'IPA installé et le JIT activé, vous pourrez jouer à vos jeux PS2 préférés sur votre iPhone 12 Pro !

**Note** : La première fois peut prendre quelques essais pour activer le JIT. C'est normal, ne vous découragez pas ! 💪
